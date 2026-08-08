import CoreLocation
import MapKit
import SwiftUI
import UIKit

enum LiveRenderDiagnostics {
    static let enabled = false
}

/// Memoizes expensive Live feed derivations across SwiftUI body re-evaluations.
private final class LiveFeedMemoCache<Value, Key: Equatable> {
    private var key: Key?
    private var value: Value?

    func resolve(key: Key, builder: () -> Value) -> Value {
        if self.key == key, let value {
            return value
        }
        let built = builder()
        self.key = key
        self.value = built
        return built
    }
}

struct LiveScreen: View {
    private static let liveAutoRefreshIntervalNanoseconds: UInt64 = 15_000_000_000
    private static let liveActivationDebounceNanoseconds: UInt64 = 275_000_000
    /// Aligns with the 15s Live auto-refresh cadence for time-sensitive venue energy windows.
    private static let liveFeedEnergyTimeSlotSeconds: TimeInterval = 15

    @ObservedObject var viewModel: MapViewModel
    @ObservedObject private var fanUpdatesStore: FanUpdatesRealtimeStore
    /// Intentionally not `@ObservedObject`: Chat publishes must not rebuild Live.
    /// Friendship chips for live-energy use equality-gated `@State` via `onReceive`.
    let chatViewModel: ChatViewModel
    @Binding var selectedTab: MainTabView.AppTab

    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @AppStorage(FavoriteTeamsStore.appStorageKey) private var favoriteTeamIDsRaw: String = ""
    @AppStorage(LiveLeagueCountryFilterPreference.appStorageKey) private var liveLeagueCountryFilterRaw: String = ""
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var activeSheet: LiveScreenActiveSheet?
    @State private var acceptedFriendUserIDs: Set<UUID> = []
    @State private var fanFeatureGateAlertMessage: String?
    @State private var liveAutoRefreshTask: Task<Void, Never>?
    @State private var liveGamesSportFilter: LiveSportVisualType?
    @State private var liveFeaturedEventFilterSlug: String?
    @State private var liveNowExpanded = false
    @State private var liveNowFeedRowsExpanded = false
    @State private var liveUpcomingFeedRowsExpanded = false
    @State private var liveActivationRefreshTask: Task<Void, Never>?
    @State private var liveFeedMemoCache = LiveFeedMemoCache<LiveFeedComputedData, LiveFeedCacheKey>()
    @State private var liveTabMatchesMemoCache = LiveFeedMemoCache<LiveTabMatchesSnapshot, LiveTabMatchesCacheKey>()
    @State private var liveFeedNativeAdLayoutWidth: CGFloat = 320

    private static let liveGameFeedInitialRowCap = 12

    private struct LiveWatchSpotsPresentation: Identifiable {
        let id: String
        let items: [LiveFeedItem]
    }

    private enum LiveScreenActiveSheet: Identifiable {
        case venueDetails
        case venueRating
        case watchSpots(LiveWatchSpotsPresentation)
        case matchDetail(LiveMatch)
        case proGamePrediction(ProGamePredictionSheetContext)
        case countryFilter
        case fanUpdates(FanUpdatesSheetEvent)

        var id: String {
            switch self {
            case .venueDetails:
                return "venueDetails"
            case .venueRating:
                return "venueRating"
            case .watchSpots(let presentation):
                return "watchSpots-\(presentation.id)"
            case .matchDetail(let match):
                return "matchDetail-\(match.id)"
            case .proGamePrediction(let context):
                return "proGamePrediction-\(context.id)"
            case .countryFilter:
                return "countryFilter"
            case .fanUpdates(let event):
                return "fanUpdates-\(event.id)"
            }
        }
    }

    private struct LiveFeedItem: Identifiable {
        let id: String
        let bar: BarVenue
        let event: SportsEvent
        let venueEventID: UUID?
        let energy: FanGeoLiveEnergy
        let score: Int
        let vibeCount: Int
        let topVibeText: String?
    }

    /// Real FanGeo momentum for a venue/game today (no synthetic activity).
    private struct LiveCrowdMomentum: Identifiable {
        let item: LiveFeedItem
        let score: Int
        let goingCount: Int
        let chatCount: Int
        let topVibeLabel: String?
        let homeCrowdFanCount: Int

        var id: String { item.id }
        var showsFriendAvatars: Bool { !item.energy.socialPresenceProfiles.isEmpty }
    }

    fileprivate struct FavoriteTeamLiveItem: Identifiable {
        let id: String
        let team: FavoriteTeam
        let title: String
        let scoreRows: [LiveMatchTeamScoreRow]?
        let leagueSportText: String
        let tvDisplayText: String?
        let scorerSummaryText: String?
        let statusText: String
        let canonicalStatus: LiveCanonicalMatchStatus
        let isLiveNow: Bool
        let startsSoon: Bool
        let isRecentFinalFallback: Bool
        let nearbyFanCount: Int
        let nearbyVenueCount: Int
        let friendGoingCount: Int
        let activityCount: Int
        let score: Int
        let startDate: Date?
        let primaryMatch: LiveMatch?
        let awayTeam: String?
        let homeTeam: String?
        let awayScore: Int?
        let homeScore: Int?
        let scoresAvailable: Bool
        let awayBadgeURL: String?
        let homeBadgeURL: String?

        var socialTokens: [String] {
            var tokens: [String] = []
            if nearbyFanCount > 0 {
                tokens.append(nearbyFanCount == 1 ? "1 fan going nearby" : "\(nearbyFanCount) fans going nearby")
            }
            if nearbyVenueCount > 0 {
                tokens.append(nearbyVenueCount == 1 ? "1 venue showing" : "\(nearbyVenueCount) venues showing")
            }
            if friendGoingCount > 0 {
                tokens.append(friendGoingCount == 1 ? "1 friend going" : "\(friendGoingCount) friends going")
            }
            if activityCount > 0 {
                tokens.append(activityCount == 1 ? "1 crowd update" : "\(activityCount) crowd updates")
            }
            return tokens
        }
    }

    fileprivate struct LiveMatchTeamScoreRow: Identifiable {
        let id: String
        let teamName: String
        let score: Int
        let badgeURL: String?
    }

    private struct LiveFeedCacheKey: Equatable {
        let calendarDayStart: TimeInterval
        let liveMatchesFingerprint: Int
        let barsFingerprint: Int
        let mapVisibleBarsFingerprint: Int
        let eventsTodayFingerprint: Int
        let venueEventRowsFingerprint: Int
        let vibeCountsFingerprint: Int
        let goingProfilesFingerprint: Int
        let venueEventInterestFingerprint: Int
        let pickupGamesFingerprint: Int
        let favoriteTeamIDsRaw: String
        let liveLeagueCountryFilterRaw: String
        let friendUserIDsFingerprint: Int
        let canShowPersonalLiveSections: Bool
        let isBusinessLiveAudienceUser: Bool
        let energyTimeSlot: Int
    }

    private struct LiveFeedComputedData {
        let rankedItems: [LiveFeedItem]
        let favoriteTeamItems: [FavoriteTeamLiveItem]
        let matchRelatedItemsByMatchID: [String: [LiveFeedItem]]
        let venuesAndPickupToday: [LiveVenuesPickupRow]
        let friendsGoing: [LiveFeedItem]
        let crowdBuilding: [LiveCrowdMomentum]
    }

    private struct LiveTabMatchesSnapshot {
        let todayBase: [LiveMatch]
        let displayed: [LiveMatch]
        let liveNow: [LiveMatch]
        let todayUpcoming: [LiveMatch]
        let sportFilterOptions: [LiveSportVisualType]
    }

    private struct LiveTabMatchesCacheKey: Equatable {
        let calendarDayStart: TimeInterval
        let liveMatchesFingerprint: Int
        let savedProGamesFingerprint: Int
        let featuredEventSlug: String?
        let sportFilter: String?
        let liveLeagueCountryFilterRaw: String
        let timeZoneIdentifier: String
    }

    init(
        viewModel: MapViewModel,
        chatViewModel: ChatViewModel,
        selectedTab: Binding<MainTabView.AppTab>
    ) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        _fanUpdatesStore = ObservedObject(wrappedValue: viewModel.fanUpdatesStore)
        self.chatViewModel = chatViewModel
        _selectedTab = selectedTab
    }

    private func refreshAcceptedFriendUserIDs(
        from chips: [UUID: ChatViewModel.FriendshipChipKind]? = nil,
        reason: String
    ) {
        let source = chips ?? chatViewModel.friendshipChipByOtherUserId
        let next: Set<UUID>
        if viewModel.canUseFanSocialFeatures {
            next = Set(source.compactMap { userID, kind in
                kind == .friends ? userID : nil
            })
        } else {
            next = []
        }
        guard next != acceptedFriendUserIDs else {
            SwiftUIRecompPerf.identicalSnapshotSkipped(source: "live.acceptedFriends.\(reason)", rows: next.count)
            return
        }
        acceptedFriendUserIDs = next
        SwiftUIRecompPerf.immutableSnapshotPublished(source: "live.acceptedFriends.\(reason)", rows: next.count)
        SwiftUIRecompPerf.rootInvalidated(screen: "Live", source: "acceptedFriends.\(reason)")
    }

    private var isBusinessLiveAudienceUser: Bool {
        viewModel.currentUserIsBusinessAccount || viewModel.isVenueOwnerLoggedIn || viewModel.hasAuthenticatedVenueOwnerSession
    }

    private var canShowPersonalLiveSections: Bool {
        viewModel.canUseFanSocialFeatures
    }

    private var liveUserCalendar: Calendar {
        var calendar = Calendar.current
        calendar.timeZone = viewModel.selectedTimeZone.resolvedTimeZone()
        return calendar
    }

    private var liveCalendarToday: Date {
        liveUserCalendar.startOfDay(for: Date())
    }

    private func liveTodayMatchesBase(calendarDay: Date) -> [LiveMatch] {
        viewModel.liveTabTodayMatchesDisplayed(
            searchQuery: "",
            sportFilter: nil,
            calendarDay: calendarDay,
            calendar: liveUserCalendar
        )
    }

    private func resolvedLiveTabMatchesSnapshot(calendarDay: Date) -> LiveTabMatchesSnapshot {
        let cacheKey = makeLiveTabMatchesCacheKey(calendarDay: calendarDay)
        return liveTabMatchesMemoCache.resolve(key: cacheKey) {
            buildLiveTabMatchesSnapshot(calendarDay: calendarDay)
        }
    }

    private func makeLiveTabMatchesCacheKey(calendarDay: Date) -> LiveTabMatchesCacheKey {
        let dayStart = liveUserCalendar.startOfDay(for: calendarDay)
        var liveMatchesHasher = Hasher()
        for match in viewModel.liveMatches {
            liveMatchesHasher.combine(match.id)
            liveMatchesHasher.combine(match.matchStatus)
            liveMatchesHasher.combine(match.startTime.timeIntervalSince1970)
            // Score/clock fields must participate: the memoized snapshot stores LiveMatch
            // value copies, so a score-only update with identical IDs would otherwise
            // cache-hit and keep rendering stale scores in the Live cards.
            liveMatchesHasher.combine(match.scoreHome)
            liveMatchesHasher.combine(match.scoreAway)
            liveMatchesHasher.combine(match.minute)
            liveMatchesHasher.combine(match.liveClockText)
        }
        var savedHasher = Hasher()
        savedHasher.combine(viewModel.savedProGames.count)
        for game in viewModel.savedProGames {
            savedHasher.combine(game.stableKey)
            savedHasher.combine(game.featuredEventSlug)
            savedHasher.combine(game.league)
        }
        return LiveTabMatchesCacheKey(
            calendarDayStart: dayStart.timeIntervalSince1970,
            liveMatchesFingerprint: liveMatchesHasher.finalize(),
            savedProGamesFingerprint: savedHasher.finalize(),
            featuredEventSlug: liveFeaturedEventFilterSlug,
            sportFilter: liveGamesSportFilter?.rawValue,
            liveLeagueCountryFilterRaw: liveLeagueCountryFilterRaw,
            timeZoneIdentifier: viewModel.selectedTimeZone.identifier
        )
    }

    private func buildLiveTabMatchesSnapshot(calendarDay: Date) -> LiveTabMatchesSnapshot {
        if viewModel.isLoadingLiveMatches && viewModel.liveMatches.isEmpty {
            return LiveTabMatchesSnapshot(
                todayBase: [],
                displayed: [],
                liveNow: [],
                todayUpcoming: [],
                sportFilterOptions: []
            )
        }

        let todayBase = liveTodayMatchesBase(calendarDay: calendarDay)
        let savedProGamesByKey = Dictionary(
            uniqueKeysWithValues: viewModel.savedProGames.map { ($0.stableKey, $0) }
        )
        let sportFiltered: [LiveMatch]
        if selectedLiveFeaturedEvent == nil, let liveGamesSportFilter {
            sportFiltered = todayBase.filter { $0.liveSportVisualType == liveGamesSportFilter }
        } else {
            sportFiltered = todayBase
        }

        let displayed: [LiveMatch]
        if let selectedLiveFeaturedEvent {
            displayed = sportFiltered.filter { match in
                let linked = savedProGamesByKey[SavedProGame.stableKey(for: match)]
                    ?? savedProGamesByKey[match.id]
                return LiveMatchFilters.matchesFeaturedEvent(
                    match,
                    featuredEvent: selectedLiveFeaturedEvent,
                    linkedSavedProGame: linked
                )
            }
            logLiveFeaturedFilterSummary(
                todayBase: todayBase,
                afterFeaturedFilter: displayed
            )
        } else {
            displayed = liveMatchesFilteredBySelectedCountries(sportFiltered)
        }

        let liveNow = liveNowMatches(from: displayed)
        let todayUpcoming = liveTodayUpcomingMatches(from: displayed, calendarDay: calendarDay)
#if DEBUG
        logLiveStatusAuditForTodayUpcoming(todayUpcoming)
#endif
        let sportFilterOptions = liveGamesSportFilterOptions(from: todayBase)
        return LiveTabMatchesSnapshot(
            todayBase: todayBase,
            displayed: displayed,
            liveNow: liveNow,
            todayUpcoming: todayUpcoming,
            sportFilterOptions: sportFilterOptions
        )
    }

#if DEBUG
    private func logLiveStatusAuditForTodayUpcoming(_ matches: [LiveMatch]) {
        let now = Date()
        let tz = liveUserCalendar.timeZone.identifier
        for match in matches {
            let pastStart = match.startTime < now
            let hasScore = match.scoreHome > 0 || match.scoreAway > 0
            guard match.matchStatus == .scheduled, pastStart || hasScore else { continue }
            let badge = Calendar.current.isDate(match.startTime, inSameDayAs: liveCalendarToday) ? "TODAY" : "UPCOMING"
            print(
                "[LiveStatusAudit] section=todayUpcoming id=\(match.id) externalId=\(match.externalId ?? "nil") " +
                "source=\(match.source ?? "nil") teams=\(match.awayTeam)@\(match.homeTeam) " +
                "rawStatus=\(match.rawMatchStatus ?? "nil") normalized=\(match.matchStatus.rawValue) " +
                "isHappeningNow=\(match.matchStatus.isHappeningNow) " +
                "score=\(match.scoreAway)-\(match.scoreHome) scoresAvailable=\(match.scoresAreAvailable) " +
                "clock=\(match.liveClockText ?? "nil") minute=\(match.minute.map(String.init) ?? "nil") " +
                "start=\(match.startTime.timeIntervalSince1970) now=\(now.timeIntervalSince1970) tz=\(tz) " +
                "badge=\(badge) pastStart=\(pastStart)"
            )
        }
    }
#endif

    private func liveNowMatches(from displayed: [LiveMatch]) -> [LiveMatch] {
        displayed.filter(\.matchStatus.isHappeningNow)
    }

    private func liveTodayUpcomingMatches(from displayed: [LiveMatch], calendarDay: Date) -> [LiveMatch] {
        let cal = liveUserCalendar
        return displayed
            .filter { $0.matchStatus == .scheduled || $0.matchStatus == .fullTime }
            .filter { cal.isDate($0.startTime, inSameDayAs: calendarDay) }
            .sorted(by: todayUpcomingLiveMatchSort)
    }

    private func liveGamesSportFilterOptions(from todayBase: [LiveMatch]) -> [LiveSportVisualType] {
        let present = Set(todayBase.map(\.liveSportVisualType))
        return LiveSportVisualType.allCases.filter { present.contains($0) }
    }

    private var liveGamesSportFilterOptions: [LiveSportVisualType] {
        resolvedLiveTabMatchesSnapshot(calendarDay: liveCalendarToday).sportFilterOptions
    }

    private func todayUpcomingLiveMatchSort(_ lhs: LiveMatch, _ rhs: LiveMatch) -> Bool {
        let lhsRank = todayUpcomingStatusSortRank(lhs.matchStatus)
        let rhsRank = todayUpcomingStatusSortRank(rhs.matchStatus)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
        return "\(lhs.awayTeam) \(lhs.homeTeam)".localizedCaseInsensitiveCompare("\(rhs.awayTeam) \(rhs.homeTeam)") == .orderedAscending
    }

    private func todayUpcomingStatusSortRank(_ status: MatchStatus) -> Int {
        if status.isHappeningNow { return 0 }
        if status == .scheduled { return 1 }
        if status == .fullTime { return 2 }
        return 3
    }

    private var liveFeaturedEvents: [FeaturedEvent] {
        viewModel.activeFeaturedEvents
    }

    private var selectedLiveFeaturedEvent: FeaturedEvent? {
        guard let liveFeaturedEventFilterSlug else { return nil }
        return liveFeaturedEvents.first { $0.slug == liveFeaturedEventFilterSlug }
    }

    private func selectedFeaturedEvent(for match: LiveMatch) -> FeaturedEvent? {
        if let featuredEventSlug = match.featuredEventSlug {
            let normalizedSlug = LiveMatchFilters.normalizedSearchText(featuredEventSlug)
            if let direct = liveFeaturedEvents.first(where: { LiveMatchFilters.normalizedSearchText($0.slug) == normalizedSlug }) {
                return direct
            }
        }
        return liveFeaturedEvents.first {
            LiveMatchFilters.matchesFeaturedEvent(
                match,
                featuredEvent: $0,
                linkedSavedProGame: viewModel.savedProGames.first {
                    $0.stableKey == SavedProGame.stableKey(for: match) || $0.id == match.id
                }
            )
        }
    }

    private var liveLeagueCountryFilterSelection: LiveLeagueCountryFilterSelection {
        LiveLeagueCountryFilterPreference.decodeSelection(from: liveLeagueCountryFilterRaw)
    }

    private var selectedLiveLeagueCountries: Set<String> {
        liveLeagueCountryFilterSelection.effectiveCountries
    }

    private var liveLeagueCountryFilterCount: Int {
        let selection = liveLeagueCountryFilterSelection
        return selection.groups.count + selection.displayCountries.count
    }

    private var liveLeagueCountryFilterIsActive: Bool {
        !liveLeagueCountryFilterSelection.isEmpty
    }

    private var liveLeagueCountryChipTitle: String {
        let languageCode = liveNowLanguageCode
        let count = liveLeagueCountryFilterCount
        if count == 0 {
            return L10n.t("Countries", languageCode: languageCode)
        }
        let key = count == 1 ? "countries_chip_count_one_format" : "countries_chip_count_other_format"
        return String(
            format: L10n.t(key, languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            Int64(count)
        )
    }

    private var liveNowLanguageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var liveHeaderPlaceMode: LiveLeagueCountryFilterPresentation.LiveHeaderPlaceMode {
        LiveLeagueCountryFilterPresentation.liveHeaderPlaceMode(
            for: liveLeagueCountryFilterSelection,
            languageCode: liveNowLanguageCode
        )
    }

    private var liveNearYouSuggestedCountry: String? {
        LiveLeagueCountryFilterPresentation.suggestedNearYouCountry(
            deviceCountryInMemory: nil,
            localeRegionCode: LiveLeagueCountryFilterPresentation.deviceLocaleRegionCode()
        )
    }

    private var liveNowSectionTitle: String {
        let languageCode = liveNowLanguageCode
        let locale = Locale(identifier: languageCode)
        let sportLabel: String? = {
            guard selectedLiveFeaturedEvent == nil else { return nil }
            return liveGamesSportFilter?.filterChipLabel
        }()

        switch liveHeaderPlaceMode {
        case .none, .summary:
            if let sportLabel {
                return String(
                    format: L10n.t("live_now_title_sport_format", languageCode: languageCode),
                    locale: locale,
                    sportLabel
                )
            }
            return L10n.t("live_now_title", languageCode: languageCode)
        case .inline(let place):
            if let sportLabel {
                return String(
                    format: L10n.t("live_now_title_sport_in_place_format", languageCode: languageCode),
                    locale: locale,
                    sportLabel,
                    place
                )
            }
            return String(
                format: L10n.t("live_now_title_in_place_format", languageCode: languageCode),
                locale: locale,
                place
            )
        }
    }

    private var liveNowSectionSubtitle: String {
        let languageCode = liveNowLanguageCode
        let locale = Locale(identifier: languageCode)
        let sportLabel: String? = {
            guard selectedLiveFeaturedEvent == nil else { return nil }
            return liveGamesSportFilter?.filterChipLabel
        }()

        switch liveHeaderPlaceMode {
        case .none:
            return L10n.t("live_now_subtitle_default", languageCode: languageCode)
        case .summary(let summary):
            return summary
        case .inline(let place):
            if let sportLabel {
                return String(
                    format: L10n.t("live_now_subtitle_sport_in_place_format", languageCode: languageCode),
                    locale: locale,
                    sportLabel,
                    place
                )
            }
            return String(
                format: L10n.t("live_now_subtitle_in_place_format", languageCode: languageCode),
                locale: locale,
                place
            )
        }
    }

    private var liveNowSectionUsesCountrySummarySubtitle: Bool {
        if case .summary = liveHeaderPlaceMode { return true }
        return false
    }

    private func liveHeaderCompactCountLabel(count: Int, oneKey: String, otherKey: String) -> String {
        let languageCode = liveNowLanguageCode
        let key = count == 1 ? oneKey : otherKey
        return String(
            format: L10n.t(key, languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            Int64(count)
        )
    }

    private func liveHeaderLiveCountLabel(_ count: Int) -> String {
        liveHeaderCompactCountLabel(
            count: count,
            oneKey: "live_header_live_count_one_format",
            otherKey: "live_header_live_count_other_format"
        )
    }

    private func liveHeaderTodayCountLabel(_ count: Int) -> String {
        liveHeaderCompactCountLabel(
            count: count,
            oneKey: "live_header_today_count_one_format",
            otherKey: "live_header_today_count_other_format"
        )
    }

    private func liveHeaderLiveCountAccessibilityPhrase(_ count: Int) -> String {
        liveHeaderCompactCountLabel(
            count: count,
            oneKey: "live_header_live_count_a11y_one_format",
            otherKey: "live_header_live_count_a11y_other_format"
        )
    }

    private func liveHeaderTodayCountAccessibilityPhrase(_ count: Int) -> String {
        liveHeaderCompactCountLabel(
            count: count,
            oneKey: "live_header_today_count_a11y_one_format",
            otherKey: "live_header_today_count_a11y_other_format"
        )
    }

    /// VoiceOver: “Live Now in North America, 1 game live, 20 games today” (no spoken bullet).
    private func liveNowSectionAccessibilityLabel(liveCount: Int, todayCount: Int) -> String {
        let languageCode = liveNowLanguageCode
        let locale = Locale(identifier: languageCode)
        let title = liveNowSectionTitle
        let livePhrase = liveHeaderLiveCountAccessibilityPhrase(liveCount)
        let todayPhrase = liveHeaderTodayCountAccessibilityPhrase(todayCount)
        switch liveHeaderPlaceMode {
        case .none, .inline:
            return String(
                format: L10n.t("live_header_summary_a11y_format", languageCode: languageCode),
                locale: locale,
                title,
                livePhrase,
                todayPhrase
            )
        case .summary:
            let spokenPlaces = LiveLeagueCountryFilterPresentation.multiCountryAccessibilitySummary(
                for: liveLeagueCountryFilterSelection,
                languageCode: languageCode
            )
            return String(
                format: L10n.t("live_header_summary_a11y_with_selection_format", languageCode: languageCode),
                locale: locale,
                title,
                livePhrase,
                todayPhrase,
                spokenPlaces
            )
        }
    }

    private var liveLeagueCountryOptions: [String] {
        let allMatches = viewModel.liveTabTodayMatchesDisplayed(searchQuery: "", sportFilter: nil, calendarDay: liveCalendarToday)
        let detected = allMatches.compactMap(\.leagueCountry)
        return Array(Set(LiveLeagueCountryResolver.presetCountries + detected + Array(selectedLiveLeagueCountries))).sorted()
    }

    private var userSelectedTimeZone: TimeZone {
        viewModel.selectedTimeZone.resolvedTimeZone()
    }

    private func formattedLocalGameStartTime(_ startTime: Date, includeLocalPrefix: Bool = false) -> String {
        let displayed = CompactGameTimeFormatter.timeWithZone(
            for: startTime,
            timeZoneOption: viewModel.selectedTimeZone
        )
#if DEBUG
        if LiveRenderDiagnostics.enabled {
            print("[LiveGameTimeDebug] rawStartTime=\(startTime)")
            print("[LiveGameTimeDebug] userTimeZone=\(userSelectedTimeZone.identifier)")
            print("[LiveGameTimeDebug] displayedStartTime=\(displayed)")
        }
#endif
        return displayed
    }

    private func updateSelectedLiveLeagueCountries(_ countries: Set<String>) {
        liveLeagueCountryFilterRaw = LiveLeagueCountryFilterPreference.encode(countries)
        LiveLeagueCountryFilterPreference.markInitialized()
    }

    private func updateLiveLeagueCountryFilterSelection(_ selection: LiveLeagueCountryFilterSelection) {
        liveLeagueCountryFilterRaw = LiveLeagueCountryFilterPreference.encode(selection)
        LiveLeagueCountryFilterPreference.markInitialized()
    }

    private func applyLiveLeagueCountryFilterFirstUseDefaultIfNeeded() {
        Task { @MainActor in
            await applyLiveLeagueCountryFilterFirstUseDefaultAsync()
        }
    }

    private func applyLiveLeagueCountryFilterFirstUseDefaultAsync() async {
        guard !LiveLeagueCountryFilterPreference.isInitialized else { return }
        let existing = LiveLeagueCountryFilterPreference.decodeSelection(from: liveLeagueCountryFilterRaw)
        guard existing.isEmpty else {
            LiveLeagueCountryFilterPreference.markInitialized()
            return
        }

        let resolved = await resolveLiveFilterCurrentCountry()
        guard let encoded = LiveLeagueCountryFilterPreference.firstUseDefaultEncodedSelection(
            currentRaw: liveLeagueCountryFilterRaw,
            resolvedCountry: resolved
        ) else { return }
        liveLeagueCountryFilterRaw = encoded
    }

    /// Current country for first-use defaults: GPS reverse-geocode → locale region. Never hometown.
    private func resolveLiveFilterCurrentCountry() async -> String? {
        if let coordinate = viewModel.currentUserLocation,
           let fromLocation = await liveFilterCountryName(from: coordinate) {
            return fromLocation
        }
        if await viewModel.refreshCurrentUserLocationIfAuthorized(timeoutSeconds: 3),
           let coordinate = viewModel.currentUserLocation,
           let fromLocation = await liveFilterCountryName(from: coordinate) {
            return fromLocation
        }
        return LiveLeagueCountryFilterPresentation.resolveCurrentCountryForFilterDefault(
            localeRegionCode: LiveLeagueCountryFilterPresentation.deviceLocaleRegionCode()
        )
    }

    private func liveFilterCountryName(from coordinate: CLLocationCoordinate2D) async -> String? {
        let result = await viewModel.reverseGeocodeBusinessVenueLocation(for: coordinate)
        return LiveLeagueCountryFilterPresentation.countryName(forRegionCode: result.countryCode)
    }

    private func liveMatchesFilteredBySelectedCountries(_ matches: [LiveMatch]) -> [LiveMatch] {
        LiveMatchFilters.filterByLeagueCountries(matches, selectedCountries: selectedLiveLeagueCountries)
    }

    private func liveMatchMatchesSelectedCountries(_ match: LiveMatch) -> Bool {
        LiveMatchFilters.matchesLeagueCountry(match, selectedCountries: selectedLiveLeagueCountries)
    }

    private var shouldAutoRefreshLiveMatches: Bool {
        selectedTab == .live && scenePhase == .active
    }

    private var isLiveTabSelected: Bool {
        selectedTab == .live
    }

    @ViewBuilder
    private var liveRootContent: some View {
        if isLiveTabSelected {
            liveFeedLayer
        } else {
            liveOffTabPlaceholder
        }
    }

    /// Preserved-tab shell: no feed ranking, cards, ads, or logo work while Live is off-screen.
    private var liveOffTabPlaceholder: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
    }

    private var canPresentVenueDetails: Bool {
        viewModel.selectedBar != nil
            && (viewModel.canViewDiscoverDetails() || viewModel.isGuestDiscoverMode)
    }

    private var canPresentVenueRating: Bool {
        viewModel.canRateVenues
            && viewModel.isAuthenticatedForSocialFeatures
            && viewModel.selectedBar != nil
    }

    var body: some View {
        let _ = SwiftUIRecompPerf.rootBodyEvaluated(screen: "Live")
        liveRootContent
            .sheet(item: $activeSheet) { sheet in
                liveScreenSheetContent(for: sheet)
                    .environmentObject(chatViewModel)
            }
            .alert(
                "FanGeo",
                isPresented: Binding(
                    get: { fanFeatureGateAlertMessage != nil },
                    set: { if !$0 { fanFeatureGateAlertMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {
                    fanFeatureGateAlertMessage = nil
                }
            } message: {
                Text(fanFeatureGateAlertMessage ?? "")
            }
            .onAppear {
                refreshAcceptedFriendUserIDs(reason: "appear")
                applyLiveLeagueCountryFilterFirstUseDefaultIfNeeded()
                logLiveFeedRefresh(reason: "appear")
                logLiveAudienceDebug()
                updateLiveAutoRefreshForCurrentState(scheduleActivationRefresh: isLiveTabSelected)
            }
            .onDisappear {
                liveActivationRefreshTask?.cancel()
                liveActivationRefreshTask = nil
                stopLiveAutoRefresh()
            }
            .onChange(of: selectedTab) { _, _ in
                updateLiveAutoRefreshForCurrentState(scheduleActivationRefresh: selectedTab == .live)
            }
            .onChange(of: scenePhase) { _, phase in
                updateLiveAutoRefreshForCurrentState(scheduleActivationRefresh: phase == .active && selectedTab == .live)
            }
            .onChange(of: viewModel.canUseFanSocialFeatures) { _, _ in
                refreshAcceptedFriendUserIDs(reason: "socialGate")
            }
            .onReceive(chatViewModel.$friendshipChipByOtherUserId) { chips in
                refreshAcceptedFriendUserIDs(from: chips, reason: "friendshipChips")
            }
    }

    private func resolvedLiveFeedComputedData(calendarDay: Date, matchCandidates: [LiveMatch]) -> LiveFeedComputedData {
        let cacheKey = makeLiveFeedCacheKey(calendarDay: calendarDay)
        return liveFeedMemoCache.resolve(key: cacheKey) {
            buildLiveFeedComputedData(calendarDay: calendarDay, matchCandidates: matchCandidates)
        }
    }

    private func makeLiveFeedCacheKey(calendarDay: Date) -> LiveFeedCacheKey {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: calendarDay)

        var liveMatchesHasher = Hasher()
        for match in viewModel.liveMatches {
            liveMatchesHasher.combine(match.id)
            liveMatchesHasher.combine(match.matchStatus)
            liveMatchesHasher.combine(match.scoreHome)
            liveMatchesHasher.combine(match.scoreAway)
            liveMatchesHasher.combine(match.minute)
        }

        var barsHasher = Hasher()
        barsHasher.combine(viewModel.bars.count)
        for bar in viewModel.bars {
            barsHasher.combine(bar.id)
        }

        var mapVisibleBarsHasher = Hasher()
        mapVisibleBarsHasher.combine(viewModel.mapVisibleBars.count)
        for bar in viewModel.mapVisibleBars {
            mapVisibleBarsHasher.combine(bar.id)
        }

        var eventsHasher = Hasher()
        let todayEvents = viewModel.events.filter { cal.isDate($0.date, inSameDayAs: dayStart) }
        eventsHasher.combine(todayEvents.count)
        for event in todayEvents {
            eventsHasher.combine(event.id)
            eventsHasher.combine(event.title)
            eventsHasher.combine(event.date.timeIntervalSince1970)
        }

        var venueEventRowsHasher = Hasher()
        venueEventRowsHasher.combine(viewModel.venueEventRows.count)
        for row in viewModel.venueEventRows {
            venueEventRowsHasher.combine(row.id)
            venueEventRowsHasher.combine(row.scheduled_start_at)
        }

        var vibeHasher = Hasher()
        for (venueEventID, counts) in fanUpdatesStore.venueEventVibeCounts {
            vibeHasher.combine(venueEventID)
            for (vibe, count) in counts {
                vibeHasher.combine(vibe)
                vibeHasher.combine(count)
            }
        }

        var goingProfilesHasher = Hasher()
        goingProfilesHasher.combine(viewModel.goingProfilesByVenueEventID.count)
        for (venueEventID, profiles) in viewModel.goingProfilesByVenueEventID.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            goingProfilesHasher.combine(venueEventID)
            goingProfilesHasher.combine(profiles.count)
        }

        var interestHasher = Hasher()
        interestHasher.combine(viewModel.venueEventInterestCounts.count)
        for (venueEventID, count) in viewModel.venueEventInterestCounts {
            interestHasher.combine(venueEventID)
            interestHasher.combine(count)
        }

        var pickupHasher = Hasher()
        for row in pickupGamesForLiveToday() {
            pickupHasher.combine(row.id)
            pickupHasher.combine(row.approvedJoinCount)
            pickupHasher.combine(row.game_start_at)
        }

        var friendHasher = Hasher()
        for userID in acceptedFriendUserIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            friendHasher.combine(userID)
        }

        let energyTimeSlot = Int(Date().timeIntervalSince1970 / Self.liveFeedEnergyTimeSlotSeconds)

        return LiveFeedCacheKey(
            calendarDayStart: dayStart.timeIntervalSince1970,
            liveMatchesFingerprint: liveMatchesHasher.finalize(),
            barsFingerprint: barsHasher.finalize(),
            mapVisibleBarsFingerprint: mapVisibleBarsHasher.finalize(),
            eventsTodayFingerprint: eventsHasher.finalize(),
            venueEventRowsFingerprint: venueEventRowsHasher.finalize(),
            vibeCountsFingerprint: vibeHasher.finalize(),
            goingProfilesFingerprint: goingProfilesHasher.finalize(),
            venueEventInterestFingerprint: interestHasher.finalize(),
            pickupGamesFingerprint: pickupHasher.finalize(),
            favoriteTeamIDsRaw: favoriteTeamIDsRaw,
            liveLeagueCountryFilterRaw: liveLeagueCountryFilterRaw,
            friendUserIDsFingerprint: friendHasher.finalize(),
            canShowPersonalLiveSections: canShowPersonalLiveSections,
            isBusinessLiveAudienceUser: isBusinessLiveAudienceUser,
            energyTimeSlot: energyTimeSlot
        )
    }

    private func buildLiveFeedComputedData(calendarDay: Date, matchCandidates: [LiveMatch]) -> LiveFeedComputedData {
        let rankedItems = liveRankedItems(for: calendarDay)
        let showPersonalLiveSections = canShowPersonalLiveSections
        let favoriteTeamItems = showPersonalLiveSections ? favoriteTeamsLiveItems(rankedItems: rankedItems) : []
        let showVenuesAndPickupToday = !isBusinessLiveAudienceUser
        let venuesAndPickupToday = showVenuesAndPickupToday ? venuesAndPickupTodayRows(from: rankedItems) : []
        let friendsGoing = showPersonalLiveSections
            ? Array(rankedItems.filter { $0.energy.friendGoingCount > 0 }.prefix(6))
            : []
        let crowdBuilding = liveCrowdBuildingMoments(from: rankedItems)

        var matchRelatedItemsByMatchID: [String: [LiveFeedItem]] = [:]
        matchRelatedItemsByMatchID.reserveCapacity(matchCandidates.count)
        for match in matchCandidates {
            matchRelatedItemsByMatchID[match.id] = liveMatchRelatedItems(for: match, in: rankedItems)
        }

        return LiveFeedComputedData(
            rankedItems: rankedItems,
            favoriteTeamItems: favoriteTeamItems,
            matchRelatedItemsByMatchID: matchRelatedItemsByMatchID,
            venuesAndPickupToday: venuesAndPickupToday,
            friendsGoing: friendsGoing,
            crowdBuilding: crowdBuilding
        )
    }

    private var liveFeedLayer: some View {
        let showPersonalLiveSections = canShowPersonalLiveSections
        let calendarDay = liveCalendarToday
        let tabMatches = resolvedLiveTabMatchesSnapshot(calendarDay: calendarDay)
        let todayMatchesBase = tabMatches.todayBase
        let liveTabMatches = tabMatches.displayed
        let liveNowMatches = tabMatches.liveNow
        let todayUpcomingMatches = tabMatches.todayUpcoming
        let sportFilterChipOptions = tabMatches.sportFilterOptions
        let feedComputed = resolvedLiveFeedComputedData(calendarDay: calendarDay, matchCandidates: todayMatchesBase)
        let showVenuesAndPickupToday = !isBusinessLiveAudienceUser
        let venuesAndPickupToday = showVenuesAndPickupToday ? feedComputed.venuesAndPickupToday : []
        let friendsGoing = showPersonalLiveSections ? feedComputed.friendsGoing : []
        let crowdBuilding = feedComputed.crowdBuilding
        let favoriteTeamItems = showPersonalLiveSections ? feedComputed.favoriteTeamItems : []
        let visibleSectionCount = visibleLiveSectionCount(
            matches: liveTabMatches,
            venuesAndPickupToday: venuesAndPickupToday,
            friendsGoing: friendsGoing,
            crowdBuilding: crowdBuilding
        )
        let _: Void = logLiveFeedSnapshot(
            venuesAndPickupTodayCount: venuesAndPickupToday.count,
            friendsGoingCount: friendsGoing.count
        )
        let _: Void = logFanUpdatesStoreMigrationDebug()
        let _: Void = logLivePolishSnapshot(visibleSectionCount: visibleSectionCount)

        return ZStack {
            liveBackground

            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        liveHeroHeader

                        if viewModel.sportsDataUpdateIndicatorVisible {
                            SportsDataUpdateIndicator()
                                .padding(.horizontal)
                        }

                        liveSummaryChips(
                            liveNowCount: liveSummaryLiveNowCount(
                                matches: liveNowMatches,
                                venuesAndPickup: venuesAndPickupToday
                            ),
                            todayCount: venuesAndPickupToday.count,
                            friendsCount: friendsGoing.count,
                            crowdCount: crowdBuilding.count,
                            showTodayChip: showVenuesAndPickupToday,
                            showFriendsChip: showPersonalLiveSections,
                            scrollToSection: { section in
                                scrollToLiveSection(section, proxy: scrollProxy)
                            }
                        )

                        if showPersonalLiveSections {
                            FavoriteTeamsLiveSection(
                                items: favoriteTeamItems,
                                favoriteTeams: favoriteTeams,
                                hasFavoriteTeams: !favoriteTeams.isEmpty,
                                onWatchNearby: { item in
                                    watchNearbyFavoriteTeam(
                                        item,
                                        matchRelatedItemsByMatchID: feedComputed.matchRelatedItemsByMatchID
                                    )
                                }
                            )
                        }
                        liveGamesSection(
                            matches: liveTabMatches,
                            liveNowMatches: liveNowMatches,
                            todayUpcomingMatches: todayUpcomingMatches,
                            matchRelatedItemsByMatchID: feedComputed.matchRelatedItemsByMatchID,
                            allLiveGames: todayMatchesBase,
                            sportFilterOptions: sportFilterChipOptions
                        )
                            .id(LiveScrollSection.liveGames.rawValue)
                        VStack(alignment: .leading, spacing: 0) {
                            if showVenuesAndPickupToday {
                                liveVenuesAndPickupTodaySection(rows: venuesAndPickupToday)
                                    .id(LiveScrollSection.today.rawValue)
                            }
                            if showPersonalLiveSections {
                                liveFriendsSection(items: friendsGoing)
                                    .id(LiveScrollSection.friends.rawValue)
                            }
                            liveCrowdBuildingSection(items: crowdBuilding)
                                .id(LiveScrollSection.crowdBuilding.rawValue)
                        }
                        .zIndex(2)
                    }
                    .padding(.horizontal, 20)
                    .background {
                        GeometryReader { geometry in
                            Color.clear
                                .allowsHitTesting(false)
                                .onAppear {
                                    updateLiveFeedNativeAdLayoutWidth(geometry.size.width)
                                }
                                .onChange(of: geometry.size.width) { _, width in
                                    updateLiveFeedNativeAdLayoutWidth(width)
                                }
                        }
                        .allowsHitTesting(false)
                    }
                    .padding(.top, 76)
                    .padding(.bottom, 112)
                }
                .refreshable {
                    await performManualLiveRefresh()
                }
            }
        }
        .ignoresSafeArea()
    }

    private func scrollToLiveSection(_ section: LiveScrollSection, proxy: ScrollViewProxy) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            proxy.scrollTo(section.rawValue, anchor: .top)
        }
    }

    private var liveBackground: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [
                    Color(red: 0.02, green: 0.035, blue: 0.045),
                    Color(red: 0.045, green: 0.065, blue: 0.085),
                    Color(red: 0.018, green: 0.028, blue: 0.036)
                ]
                : [
                    Color(red: 0.94, green: 0.97, blue: 0.965),
                    Color(red: 0.985, green: 0.995, blue: 0.99)
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.18 : 0.10))
                .frame(width: 260, height: 260)
                .blur(radius: 58)
                .offset(x: 110, y: 80)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomLeading) {
            Circle()
                .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.12 : 0.07))
                .frame(width: 240, height: 240)
                .blur(radius: 62)
                .offset(x: -120, y: -80)
                .allowsHitTesting(false)
        }
        .allowsHitTesting(false)
    }

    private var liveHeroHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            FanGeoPagePurposeHeader(
                title: L10n.t("Live", languageCode: appLanguageRaw),
                subtitle: L10n.t("live_tab_subtitle", languageCode: appLanguageRaw)
            )

            Spacer(minLength: 0)

            liveManualRefreshButton
        }
        .padding(.top, 4)
    }

    private var liveManualRefreshButton: some View {
        Button {
            Task { await performManualLiveRefresh() }
        } label: {
            HStack(spacing: 6) {
                if viewModel.isLoadingLiveMatches {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                }
                Text(L10n.t("refresh", languageCode: appLanguageRaw))
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(FGColor.accentGreen)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.16 : 0.10))
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(FGColor.accentGreen.opacity(0.28), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isLoadingLiveMatches)
        .accessibilityLabel("Refresh live games")
    }

    private func liveSummaryLiveNowCount(
        matches: [LiveMatch],
        venuesAndPickup: [LiveVenuesPickupRow]
    ) -> Int {
        matches.count + venuesAndPickup.filter(liveVenuesPickupRowIsInProgress).count
    }

    private var liveCrowdSummaryAccent: Color {
        Color(red: 0.95, green: 0.52, blue: 0.14)
    }

    private func liveSummaryChips(
        liveNowCount: Int,
        todayCount: Int,
        friendsCount: Int,
        crowdCount: Int,
        showTodayChip: Bool,
        showFriendsChip: Bool,
        scrollToSection: @escaping (LiveScrollSection) -> Void
    ) -> some View {
        let languageCode = liveNowLanguageCode
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    scrollToSection(.liveGames)
                } label: {
                    liveSummaryChip(
                        title: L10n.t("Live now", languageCode: languageCode),
                        count: liveNowCount,
                        accent: FGColor.dangerRed,
                        icon: "dot.radiowaves.left.and.right"
                    )
                }
                .buttonStyle(LiveSummaryChipButtonStyle())

                if showTodayChip {
                    Button {
                        scrollToSection(.today)
                    } label: {
                        liveSummaryChip(
                            title: L10n.t("Today", languageCode: languageCode),
                            count: todayCount,
                            accent: FGColor.accentGreen,
                            icon: "calendar"
                        )
                    }
                    .buttonStyle(LiveSummaryChipButtonStyle())
                }

                if showFriendsChip {
                    Button {
                        scrollToSection(.friends)
                    } label: {
                        liveSummaryChip(
                            title: L10n.t("Friends", languageCode: languageCode),
                            count: friendsCount,
                            accent: FGColor.accentBlue,
                            icon: "person.2.fill"
                        )
                    }
                    .buttonStyle(LiveSummaryChipButtonStyle())
                }

                Button {
                    scrollToSection(.crowdBuilding)
                } label: {
                    liveSummaryChip(
                        title: L10n.t("Crowd", languageCode: languageCode),
                        count: crowdCount,
                        accent: liveCrowdSummaryAccent,
                        icon: "flame.fill"
                    )
                }
                .buttonStyle(LiveSummaryChipButtonStyle())
            }
            .padding(.horizontal, 1)
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    private func liveSummaryChip(title: String, count: Int, accent: Color, icon: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(accent)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(count)")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(accent.opacity(colorScheme == .dark ? 0.14 : 0.09))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(accent.opacity(colorScheme == .dark ? 0.28 : 0.18), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Scrolls to the \(title) section")
    }

    private enum LiveScrollSection: String {
        case liveGames = "liveGamesSection"
        case today = "todayPlansSection"
        case friends = "friendsGoingSection"
        case crowdBuilding = "crowdBuildingSection"
    }

    private enum LiveGameFeedRow: Identifiable {
        case match(LiveMatch)
        case nativeAd(slotIndex: Int, insertionIndex: Int)

        var id: String {
            switch self {
            case .match(let match):
                return "live-match-\(match.id)"
            case .nativeAd(let slotIndex, let insertionIndex):
                return "live-native-ad-\(slotIndex)-after-\(insertionIndex)"
            }
        }
    }

    private enum LiveFeedAdPlacement {
        static let debugFrequency = 2
        static let releaseFrequency = 4

        static var insertionFrequency: Int {
#if DEBUG
            debugFrequency
#else
            releaseFrequency
#endif
        }

        static func listItems(for matches: [LiveMatch]) -> [LiveGameFeedRow] {
            guard FanGeoAdPolicy.shouldInsertAdsInFeeds() else {
                return matches.map { .match($0) }
            }
            let frequency = insertionFrequency
            guard frequency > 0, matches.count >= frequency else {
                return matches.map { .match($0) }
            }

            var items: [LiveGameFeedRow] = []
            items.reserveCapacity(matches.count + (matches.count / frequency))

            var slotIndex = 0
            for (index, match) in matches.enumerated() {
                items.append(.match(match))
                let insertionIndex = index + 1
                if insertionIndex.isMultiple(of: frequency) {
                    items.append(.nativeAd(slotIndex: slotIndex, insertionIndex: insertionIndex))
                    slotIndex += 1
                }
            }

            return items
        }

        static func logPlan(matchCount: Int) {
            guard AdDiagnostics.enabled else { return }
            let insertionIndexes = stride(from: insertionFrequency, through: matchCount, by: insertionFrequency)
                .map { $0 }
            print("[LiveFeedAdDebug] releaseFrequency=\(releaseFrequency)")
            print("[LiveFeedAdDebug] debugFrequency=\(debugFrequency)")
            for insertionIndex in insertionIndexes {
                print("[LiveFeedAdDebug] insertionIndex=\(insertionIndex)")
            }
        }
    }

    private enum LivePanelKind {
        case liveGames
        case venuesPickup
        case friendsGoing
        case crowdBuilding

        var icon: String {
            switch self {
            case .liveGames: return "sportscourt.fill"
            case .venuesPickup: return "mappin.and.ellipse"
            case .friendsGoing: return "person.2.fill"
            case .crowdBuilding: return "flame.fill"
            }
        }

        func accentColor(colorScheme: ColorScheme) -> Color {
            switch self {
            case .liveGames:
                return FGColor.dangerRed
            case .venuesPickup:
                return FGColor.accentGreen
            case .friendsGoing:
                return FGColor.accentBlue
            case .crowdBuilding:
                return Color(red: 0.95, green: 0.52, blue: 0.14)
            }
        }

        func panelFill(colorScheme: ColorScheme) -> Color {
            let accent = accentColor(colorScheme: colorScheme)
            return accent.opacity(colorScheme == .dark ? 0.10 : 0.07)
        }

        func panelStroke(colorScheme: ColorScheme) -> Color {
            accentColor(colorScheme: colorScheme).opacity(colorScheme == .dark ? 0.22 : 0.14)
        }
    }

    private func liveSocialPresenceText(_ item: LiveFeedItem) -> String {
        if let label = item.energy.socialPresenceLabel {
            return label
        }
        if canShowPersonalLiveSections && item.energy.friendGoingCount > 0 {
            return item.energy.friendPresenceLabel ?? "\(item.energy.friendGoingCount) friends going"
        }
        if item.energy.commentCount > 0 {
            return item.energy.commentCount == 1 ? "1 fan chatting" : "\(item.energy.commentCount) fans chatting"
        }
        if item.energy.goingCount >= 8 {
            return "Crowd building"
        }
        if item.energy.goingCount > 0 {
            return item.energy.goingCount == 1 ? "1 fan going" : "\(item.energy.goingCount) fans going"
        }
        return item.energy.energySubtitle ?? "Live updates appear as fans go, chat, and react."
    }

    private func liveOperationalSubtitle(for item: LiveFeedItem) -> String {
        guard isBusinessLiveAudienceUser else {
            return item.energy.energySubtitle ?? "Watch party active"
        }
        if item.energy.isLiveNow {
            return "Watch party active"
        }
        if item.energy.startsSoon, let minutes = item.energy.minutesUntilStart {
            return "Starts in \(minutes) min"
        }
        if item.energy.goingCount >= 8 {
            return "Crowd building"
        }
        if item.energy.goingCount > 0 {
            return "Venue activity signal"
        }
        return "Venue activity signal"
    }

    private func liveEnergyForCurrentAudience(_ energy: FanGeoLiveEnergy) -> FanGeoLiveEnergy {
        guard isBusinessLiveAudienceUser else { return energy }
        return FanGeoLiveEnergy(
            isLiveNow: energy.isLiveNow,
            startsSoon: energy.startsSoon,
            minutesUntilStart: energy.minutesUntilStart,
            goingCount: energy.goingCount,
            commentCount: 0,
            friendGoingCount: 0,
            friendAvatarURLs: [],
            mutualTeamLabel: nil,
            energyLabel: energy.energyLabel,
            energySubtitle: businessLiveEnergySubtitle(for: energy),
            friendPresenceLabel: nil,
            friendProfiles: [],
            socialPresenceProfiles: [],
            socialPresenceLabel: nil
        )
    }

    private func businessLiveEnergySubtitle(for energy: FanGeoLiveEnergy) -> String? {
        if energy.isLiveNow {
            return "Watch party active"
        }
        if energy.startsSoon, let minutes = energy.minutesUntilStart {
            return "Starts in \(minutes) min"
        }
        if energy.goingCount >= 8 {
            return "Crowd building"
        }
        if energy.goingCount > 0 {
            return "Venue activity signal"
        }
        return energy.energyLabel == nil ? nil : "Venue activity signal"
    }

    private func liveGamesSection(
        matches: [LiveMatch],
        liveNowMatches: [LiveMatch],
        todayUpcomingMatches: [LiveMatch],
        matchRelatedItemsByMatchID: [String: [LiveFeedItem]],
        allLiveGames: [LiveMatch],
        sportFilterOptions: [LiveSportVisualType]
    ) -> some View {
        let liveFeedRows = LiveFeedAdPlacement.listItems(for: liveNowMatches)
        let upcomingFeedRows = LiveFeedAdPlacement.listItems(for: todayUpcomingMatches)
        if LiveRenderDiagnostics.enabled {
            let _: Void = logLiveNowSectionDebug(liveNowExpanded: liveNowExpanded, liveNowCount: liveNowMatches.count)
            let _: Void = LiveFeedAdPlacement.logPlan(matchCount: liveNowMatches.count)
        }

        // Live = currently happening (`liveNow`). Today = scheduled/FT on local calendar day
        // (`todayUpcoming`); product partitions live out of the Today / Upcoming list.
        let liveCount = liveNowMatches.count
        let todayCount = todayUpcomingMatches.count
        return liveCollapsiblePanelSection(
            kind: .liveGames,
            title: liveNowSectionTitle,
            liveCount: liveCount,
            todayCount: todayCount,
            subtitle: liveNowSectionSubtitle,
            subtitleUsesSubheadline: liveNowSectionUsesCountrySummarySubtitle,
            accessibilityLabelText: liveNowSectionAccessibilityLabel(liveCount: liveCount, todayCount: todayCount),
            isExpanded: liveNowExpanded,
            toggle: toggleLiveNowExpanded
        ) {
            if liveNowExpanded {
                liveGamesSportFilterBar(sportFilterOptions: sportFilterOptions)
                if viewModel.isLoadingLiveMatches && viewModel.liveMatches.isEmpty {
                    liveGamesLoadingCard
                } else if matches.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        liveSectionEmptyState(liveGamesEmptyStateMessage)
#if DEBUG
                        if let hint = viewModel.liveMatchesEmptyDebugHint {
                            Text(hint)
                                .font(.caption2)
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .fixedSize(horizontal: false, vertical: true)
                        }
#endif
                    }
                } else {
                    LazyVStack(spacing: 10) {
                        if !liveNowMatches.isEmpty {
                            liveMatchSubsectionHeader("Live Now")
                            liveGameFeedRowsList(
                                cappedLiveGameFeedRows(liveFeedRows, showAll: liveNowFeedRowsExpanded),
                                matchRelatedItemsByMatchID: matchRelatedItemsByMatchID
                            )
                            liveGameFeedShowMoreButton(
                                totalRowCount: liveFeedRows.count,
                                isExpanded: liveNowFeedRowsExpanded
                            ) {
                                liveNowFeedRowsExpanded = true
                            }
                        }

                        if !todayUpcomingMatches.isEmpty {
                            liveMatchSubsectionHeader("Today / Upcoming")
                            liveGameFeedRowsList(
                                cappedLiveGameFeedRows(upcomingFeedRows, showAll: liveUpcomingFeedRowsExpanded),
                                matchRelatedItemsByMatchID: matchRelatedItemsByMatchID
                            )
                            liveGameFeedShowMoreButton(
                                totalRowCount: upcomingFeedRows.count,
                                isExpanded: liveUpcomingFeedRowsExpanded
                            ) {
                                liveUpcomingFeedRowsExpanded = true
                            }
                        }
                    }
                    .animation(.spring(response: 0.34, dampingFraction: 0.86), value: liveGamesSportFilter)
                    .animation(.spring(response: 0.34, dampingFraction: 0.86), value: liveFeaturedEventFilterSlug)
                    .onChange(of: liveGamesSportFilter) { _, _ in
                        liveNowFeedRowsExpanded = false
                        liveUpcomingFeedRowsExpanded = false
                    }
                    .onChange(of: liveFeaturedEventFilterSlug) { _, _ in
                        liveNowFeedRowsExpanded = false
                        liveUpcomingFeedRowsExpanded = false
                    }
                    .onChange(of: liveLeagueCountryFilterRaw) { _, _ in
                        liveNowFeedRowsExpanded = false
                        liveUpcomingFeedRowsExpanded = false
                    }
                }
            }
        }
    }

    private func liveMatchSubsectionHeader(_ title: String) -> some View {
        Text(title)
            .font(FGTypography.caption.weight(.heavy))
            .foregroundStyle(FGColor.secondaryText(colorScheme))
            .textCase(.uppercase)
            .tracking(0.7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
    }

    private func cappedLiveGameFeedRows(_ rows: [LiveGameFeedRow], showAll: Bool) -> [LiveGameFeedRow] {
        guard !showAll, rows.count > Self.liveGameFeedInitialRowCap else { return rows }
        return Array(rows.prefix(Self.liveGameFeedInitialRowCap))
    }

    @ViewBuilder
    private func liveGameFeedRowsList(
        _ rows: [LiveGameFeedRow],
        matchRelatedItemsByMatchID: [String: [LiveFeedItem]]
    ) -> some View {
        ForEach(rows) { row in
            switch row {
            case .match(let match):
                liveMatchCard(
                    match,
                    relatedItems: matchRelatedItemsByMatchID[match.id] ?? []
                )
            case .nativeAd(let slotIndex, _):
                liveFeedNativeAdCard(slotIndex: slotIndex)
            }
        }
    }

    @ViewBuilder
    private func liveGameFeedShowMoreButton(
        totalRowCount: Int,
        isExpanded: Bool,
        expand: @escaping () -> Void
    ) -> some View {
        if !isExpanded, totalRowCount > Self.liveGameFeedInitialRowCap {
            let remaining = totalRowCount - Self.liveGameFeedInitialRowCap
            Button(action: expand) {
                Text(remaining == 1 ? "Show 1 more" : "Show \(remaining) more")
                    .font(FGTypography.caption.weight(.bold))
                    .foregroundStyle(FGColor.accentBlue)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        }
    }

    private func toggleLiveNowExpanded() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            liveNowExpanded.toggle()
        }
#if DEBUG
        if LiveRenderDiagnostics.enabled {
            print("[LiveTabDebug] liveNowExpanded=\(liveNowExpanded)")
            print("[LiveTabDebug] liveNowCount=\(resolvedLiveTabMatchesSnapshot(calendarDay: liveCalendarToday).liveNow.count)")
        }
#endif
    }

    private var liveGamesEmptyStateMessage: String {
        if let selectedLiveFeaturedEvent {
            return "No \(selectedLiveFeaturedEvent.emptyStateTitle) matches scheduled for today."
        }
        if liveLeagueCountryFilterIsActive {
            return L10n.t("No live games for selected countries right now", languageCode: liveNowLanguageCode)
        }
        if let liveGamesSportFilter {
            return "No live \(liveGamesSportFilter.filterChipLabel) games right now"
        }
        return L10n.t("no_live_pro_sports_games")
    }

    private func liveGamesSportFilterBar(sportFilterOptions: [LiveSportVisualType]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                SportFilterChip(
                    sport: "All",
                    displayTitle: L10n.t("All", languageCode: liveNowLanguageCode),
                    isSelected: liveGamesSportFilter == nil && selectedLiveFeaturedEvent == nil,
                    preferSystemSymbol: true
                ) {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                        liveFeaturedEventFilterSlug = nil
                        liveGamesSportFilter = nil
                    }
                }
                liveCountryFilterChip
                ForEach(liveFeaturedEvents) { featuredEvent in
                    liveFeaturedEventChip(featuredEvent)
                }
                ForEach(sportFilterOptions, id: \.self) { sport in
                    SportFilterChip(
                        sport: sport.sportFilterCatalogKey,
                        displayTitle: sport.filterChipLabel,
                        isSelected: liveGamesSportFilter == sport && selectedLiveFeaturedEvent == nil,
                        preferSystemSymbol: true
                    ) {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                            liveFeaturedEventFilterSlug = nil
                            liveGamesSportFilter = sport
                        }
                    }
                }
            }
            .padding(.horizontal, 1)
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: liveGamesSportFilter)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: liveFeaturedEventFilterSlug)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: liveLeagueCountryFilterRaw)
    }

    private func liveFeaturedEventChip(_ featuredEvent: FeaturedEvent) -> some View {
        SportFilterChip(
            sport: featuredEvent.sport ?? "Soccer",
            displayTitle: featuredEvent.leagueChipLabel,
            isSelected: selectedLiveFeaturedEvent?.slug == featuredEvent.slug,
            preferSystemSymbol: false
        ) {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                liveGamesSportFilter = nil
                updateSelectedLiveLeagueCountries([])
                liveFeaturedEventFilterSlug = selectedLiveFeaturedEvent?.slug == featuredEvent.slug ? nil : featuredEvent.slug
                liveNowExpanded = true
            }
        }
    }

    private var liveCountryFilterChip: some View {
        Button {
            activeSheet = .countryFilter
        } label: {
            HStack(spacing: 6) {
                Text("🌎")
                    .font(.system(size: 16))
                    .baselineOffset(-0.35)
                Text(liveLeagueCountryChipTitle)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 1)
            .frame(height: 36, alignment: .center)
            .foregroundStyle(liveLeagueCountryFilterIsActive ? Color.white : FGColor.primaryText(colorScheme))
            .background {
                Group {
                    if liveLeagueCountryFilterIsActive {
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [FGColor.accentBlue.opacity(0.98), FGColor.accentBlue.opacity(0.74)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    } else {
                        ZStack {
                            Capsule(style: .continuous)
                                .fill(.ultraThinMaterial)
                            Capsule(style: .continuous)
                                .fill(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.55 : 0.72))
                            Capsule(style: .continuous)
                                .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.10 : 0.065))
                        }
                    }
                }
            }
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        liveLeagueCountryFilterIsActive ? Color.white.opacity(0.22) : FGColor.accentBlue.opacity(colorScheme == .dark ? 0.26 : 0.20),
                        lineWidth: liveLeagueCountryFilterIsActive ? 1 : 0.9
                    )
            )
            .contentShape(Capsule(style: .continuous))
            .shadow(
                color: liveLeagueCountryFilterIsActive ? FGColor.accentBlue.opacity(colorScheme == .dark ? 0.34 : 0.22) : .black.opacity(colorScheme == .dark ? 0.14 : 0.05),
                radius: liveLeagueCountryFilterIsActive ? 12 : 6,
                x: 0,
                y: liveLeagueCountryFilterIsActive ? 5 : 2.5
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(liveLeagueCountryFilterCount == 0
            ? L10n.t("Countries", languageCode: liveNowLanguageCode)
            : String(
                format: L10n.t("Countries, %lld selected", languageCode: liveNowLanguageCode),
                locale: Locale(identifier: liveNowLanguageCode),
                Int64(liveLeagueCountryFilterCount)
            )
        )
    }

    private var favoriteTeams: [FavoriteTeam] {
        FavoriteTeamsStore.resolvedTeams(from: favoriteTeamIDsRaw)
    }

    private func logLiveFeaturedFilterSummary(
        todayBase: [LiveMatch],
        afterFeaturedFilter: [LiveMatch]
    ) {
#if DEBUG
        guard selectedLiveFeaturedEvent != nil else { return }
        print("[LiveFeaturedFilter] rawCount=\(viewModel.liveMatches.count)")
        print("[LiveFeaturedFilter] afterDateFilter=\(todayBase.count)")
        print("[LiveFeaturedFilter] afterFeaturedFilter=\(afterFeaturedFilter.count)")
#endif
    }

    private func logLiveNowSectionDebug(liveNowExpanded: Bool, liveNowCount: Int) {
#if DEBUG
        print("[LiveTabDebug] liveNowExpanded=\(liveNowExpanded)")
        print("[LiveTabDebug] liveNowCount=\(liveNowCount)")
#endif
    }

    private func favoriteTeamsLiveItems(rankedItems: [LiveFeedItem]) -> [FavoriteTeamLiveItem] {
        let liveOrSoonCandidates = viewModel.liveMatches
            .filter { liveMatchIsLiveOrStartingSoon($0) }
            .filter(liveMatchMatchesSelectedCountries)
        let fullTimeCandidates = viewModel.liveMatches
            .filter { $0.matchStatus == .fullTime }
            .filter(liveMatchMatchesSelectedCountries)
        let liveIndex = FavoriteTeamLiveSnapshotIndex.build(from: liveOrSoonCandidates)
        let fullTimeIndex = FavoriteTeamLiveSnapshotIndex.build(from: fullTimeCandidates)
#if DEBUG
        LiveApplyPerf.favoriteIndexBuild(
            rows: liveOrSoonCandidates.count + fullTimeCandidates.count,
            favorites: favoriteTeams.count,
            buildMs: liveIndex.buildMs + fullTimeIndex.buildMs,
            reason: "liveFavoriteCards"
        )
#endif
        return favoriteTeams
            .compactMap {
                favoriteTeamLiveItem(
                    for: $0,
                    rankedItems: rankedItems,
                    liveOrSoonIndex: liveIndex,
                    fullTimeIndex: fullTimeIndex
                )
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return (lhs.startDate ?? .distantFuture) < (rhs.startDate ?? .distantFuture)
                }
                return lhs.score > rhs.score
            }
            .prefix(6)
            .map { $0 }
    }

    private func favoriteTeamLiveItem(
        for team: FavoriteTeam,
        rankedItems: [LiveFeedItem],
        liveOrSoonIndex: FavoriteTeamLiveSnapshotIndex,
        fullTimeIndex: FavoriteTeamLiveSnapshotIndex
    ) -> FavoriteTeamLiveItem? {
        let aliases = FavoriteTeamLiveMatcher.matchAliasesForGameDiscovery(for: team)
        let matchingLiveOrSoonMatches = liveOrSoonIndex
            .matchingMatches(aliases: aliases)
            .sorted(by: favoriteTeamLiveMatchSort)
        let matchingVenueItems = rankedItems
            .filter { favoriteTeamMatches(team, in: $0.event) }
            .filter { item in
                item.energy.startsSoon
                    || item.energy.goingCount > 0
                    || item.energy.friendGoingCount > 0
                    || item.energy.commentCount > 0
                    || item.vibeCount > 0
                    || linkedLiveMatch(for: item)?.matchStatus.isHappeningNow == true
                    || linkedLiveMatch(for: item)?.matchStatus == .fullTime
            }

        let primaryMatch: LiveMatch?
        let isRecentFinalFallback: Bool
        if let liveOrSoon = matchingLiveOrSoonMatches.first {
            primaryMatch = liveOrSoon
            isRecentFinalFallback = false
        } else if matchingLiveOrSoonMatches.isEmpty {
            primaryMatch = recentFullTimeFavoriteMatch(index: fullTimeIndex, aliases: aliases)
            isRecentFinalFallback = primaryMatch != nil
        } else {
            primaryMatch = nil
            isRecentFinalFallback = false
        }

        guard primaryMatch != nil || !matchingVenueItems.isEmpty else {
            return nil
        }

        let primaryVenueItem = matchingVenueItems.first
        let title: String = {
            if let match = primaryMatch {
                if match.scoresAreAvailable, match.matchStatus.isHappeningNow || match.matchStatus == .fullTime {
                    return "\(match.awayTeam) \(match.scoreAway)–\(match.scoreHome) \(match.homeTeam)"
                }
                return "\(match.awayTeam) vs \(match.homeTeam)"
            }
            return primaryVenueItem?.event.title ?? team.name
        }()
        let scoreRows = primaryMatch.flatMap(favoriteTeamScoreRows)
        let leagueSportText = favoriteTeamLeagueSportText(team: team, match: primaryMatch, item: primaryVenueItem)
        let tvDisplayText = primaryMatch?.tvDisplayText
        let scorerSummaryText = isRecentFinalFallback ? nil : primaryMatch?.latestScoringEvent?.displayText

        let canonicalStatus: LiveCanonicalMatchStatus = {
            if let primaryMatch {
                return LiveCanonicalMatchStatus.from(match: primaryMatch)
            }
            if let venueItem = primaryVenueItem {
                return resolveVenueEventMatchStatus(for: venueItem)
            }
            return .unknown
        }()

        let liveNow = canonicalStatus.isLive
        let soonMinutes: Int? = {
            if case .startingSoon(let minutes) = canonicalStatus { return minutes }
            return favoriteTeamSoonMinutes(matches: matchingLiveOrSoonMatches, items: matchingVenueItems)
        }()
        let startsSoon = {
            if case .startingSoon = canonicalStatus { return true }
            return soonMinutes != nil || matchingVenueItems.contains { $0.energy.startsSoon }
        }()
        let statusText = favoriteTeamStatusText(canonicalStatus: canonicalStatus, soonMinutes: soonMinutes, match: primaryMatch)
        let nearbyVenueIDs = Set(matchingVenueItems.map(\.bar.id))
        let nearbyFanCount = matchingVenueItems.reduce(0) { $0 + $1.energy.goingCount }
        let friendCount = matchingVenueItems.reduce(0) { $0 + $1.energy.friendGoingCount }
        let activityCount = matchingVenueItems.reduce(0) { $0 + $1.energy.commentCount + $1.vibeCount }
        let startDate = primaryMatch?.startTime ?? primaryVenueItem?.event.date
        let score = favoriteTeamLiveScore(
            isLiveNow: liveNow,
            startsSoon: startsSoon,
            nearbyVenueCount: nearbyVenueIDs.count,
            nearbyFanCount: nearbyFanCount,
            friendGoingCount: friendCount,
            activityCount: activityCount
        )

        let scoresAvailable = primaryMatch?.scoresAreAvailable == true
            && (primaryMatch?.matchStatus.isHappeningNow == true || primaryMatch?.matchStatus == .fullTime)

        return FavoriteTeamLiveItem(
            id: team.id,
            team: team,
            title: title,
            scoreRows: scoreRows,
            leagueSportText: leagueSportText,
            tvDisplayText: tvDisplayText,
            scorerSummaryText: scorerSummaryText,
            statusText: statusText,
            canonicalStatus: canonicalStatus,
            isLiveNow: liveNow,
            startsSoon: startsSoon,
            isRecentFinalFallback: isRecentFinalFallback,
            nearbyFanCount: nearbyFanCount,
            nearbyVenueCount: nearbyVenueIDs.count,
            friendGoingCount: friendCount,
            activityCount: activityCount,
            score: score,
            startDate: startDate,
            primaryMatch: primaryMatch,
            awayTeam: primaryMatch?.awayTeam,
            homeTeam: primaryMatch?.homeTeam,
            awayScore: scoresAvailable ? primaryMatch?.scoreAway : nil,
            homeScore: scoresAvailable ? primaryMatch?.scoreHome : nil,
            scoresAvailable: scoresAvailable,
            awayBadgeURL: primaryMatch?.awayTeamBadgeURL,
            homeBadgeURL: primaryMatch?.homeTeamBadgeURL
        )
    }

    private func recentFullTimeFavoriteMatch(
        index: FavoriteTeamLiveSnapshotIndex,
        aliases: [String]
    ) -> LiveMatch? {
        let cal = Calendar.current
        let now = Date()
        let candidates = index.matchingMatches(aliases: aliases)

        let todayCandidates = candidates.filter { cal.isDate($0.startTime, inSameDayAs: liveCalendarToday) }
        let pool: [LiveMatch]
        if !todayCandidates.isEmpty {
            pool = todayCandidates
        } else {
            // Short recent window only: completion known and still within post-game activity window,
            // or otherwise omit stale finals without inventing Discover's 4h live-energy window.
            pool = candidates.filter { match in
                guard let completion = FanGeoLivePostGameTiming.completionTime(from: match) else {
                    return false
                }
                return FanGeoLivePostGameTiming.isWithinPostGameActivityWindow(
                    completionTime: completion,
                    now: now
                )
            }
        }
        return pool.sorted { $0.startTime > $1.startTime }.first
    }

    private func linkedLiveMatch(for item: LiveFeedItem) -> LiveMatch? {
        liveMatchRelatedItems(forVenueEvent: item)
    }

    private func liveMatchRelatedItems(forVenueEvent item: LiveFeedItem) -> LiveMatch? {
        let eventText = normalizedLiveAudienceText([
            item.event.title,
            item.event.league,
            item.event.sport
        ].joined(separator: " "))
        return viewModel.liveMatches
            .filter(liveMatchMatchesSelectedCountries)
            .first { match in
                let home = normalizedLiveAudienceText(match.homeTeam)
                let away = normalizedLiveAudienceText(match.awayTeam)
                return (!home.isEmpty && eventText.contains(home))
                    || (!away.isEmpty && eventText.contains(away))
            }
    }

    private func resolveVenueEventMatchStatus(for item: LiveFeedItem) -> LiveCanonicalMatchStatus {
        if let match = linkedLiveMatch(for: item) {
            return LiveCanonicalMatchStatus.from(match: match)
        }
        let row = viewModel.cachedVenueEventRow(for: item.bar, gameTitle: item.event.title)
        let start = row.flatMap { FanGeoLiveEnergyTiming.parseScheduledStart($0.scheduled_start_at, eventId: $0.id) }
            ?? item.event.date
        return LiveCanonicalMatchStatus.from(adminStatus: row?.admin_status, eventStart: start)
    }

    private func liveMatchIsLiveOrStartingSoon(_ match: LiveMatch) -> Bool {
        if match.matchStatus.isHappeningNow { return true }
        guard match.matchStatus == .scheduled else { return false }
        if LiveCanonicalMatchStatus.from(match: match).isLive { return true }
        if case .startingSoon = LiveCanonicalMatchStatus.from(match: match) { return true }
        return false
    }

    private func favoriteTeamLiveMatchSort(_ lhs: LiveMatch, _ rhs: LiveMatch) -> Bool {
        if lhs.matchStatus.isHappeningNow != rhs.matchStatus.isHappeningNow {
            return lhs.matchStatus.isHappeningNow
        }
        return lhs.startTime < rhs.startTime
    }

    private func favoriteTeamLeagueSportText(team: FavoriteTeam, match: LiveMatch?, item: LiveFeedItem?) -> String {
        let league = match?.league.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? item?.event.league.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? team.league
        let sport = match?.liveSportVisualType.displayLabel
            ?? trimmedSportLabel(item?.event.sport)
            ?? team.sport.chipTitle
        return [league, sport]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func favoriteTeamScoreRows(_ match: LiveMatch) -> [LiveMatchTeamScoreRow]? {
        let mayShowScores = match.matchStatus.isHappeningNow || match.matchStatus == .fullTime
        guard mayShowScores, match.scoresAreAvailable else { return nil }
        return [
            LiveMatchTeamScoreRow(
                id: "away-\(match.id)",
                teamName: match.awayTeam,
                score: match.scoreAway,
                badgeURL: match.awayTeamBadgeURL
            ),
            LiveMatchTeamScoreRow(
                id: "home-\(match.id)",
                teamName: match.homeTeam,
                score: match.scoreHome,
                badgeURL: match.homeTeamBadgeURL
            )
        ]
    }

    private func favoriteTeamSoonMinutes(matches: [LiveMatch], items: [LiveFeedItem]) -> Int? {
        let matchMinutes = matches
            .filter { $0.matchStatus == .scheduled }
            .compactMap { match -> Int? in
                let secondsUntil = match.startTime.timeIntervalSince(Date())
                guard secondsUntil > 0 else { return nil }
                return Int(ceil(secondsUntil / 60))
            }
        let itemMinutes = items.compactMap(\.energy.minutesUntilStart)
        return (matchMinutes + itemMinutes).min()
    }

    private func favoriteTeamStatusText(
        canonicalStatus: LiveCanonicalMatchStatus,
        soonMinutes: Int?,
        match: LiveMatch?
    ) -> String {
        switch canonicalStatus {
        case .live(let minute):
            if let minute {
                return "LIVE \(minute)'"
            }
            return "LIVE NOW"
        case .halfTime:
            return "HT"
        case .startingSoon(let minutes):
            return "Starts in \(minutes) min"
        case .upcoming(let start):
            return "Starts \(formattedLocalGameStartTime(start))"
        case .final:
            return "FINAL"
        case .postponed:
            return "Postponed"
        case .canceled:
            return "Canceled"
        case .unknown:
            if let soonMinutes {
                return "Starts in \(soonMinutes) min"
            }
            if let match {
                return "Starts \(formattedLocalGameStartTime(match.startTime))"
            }
            return "Starting soon"
        }
    }

    private func favoriteTeamLiveScore(
        isLiveNow: Bool,
        startsSoon: Bool,
        nearbyVenueCount: Int,
        nearbyFanCount: Int,
        friendGoingCount: Int,
        activityCount: Int
    ) -> Int {
        (isLiveNow ? 100_000 : 0)
            + (startsSoon ? 60_000 : 0)
            + (friendGoingCount * 1_200)
            + (nearbyVenueCount * 500)
            + (nearbyFanCount * 140)
            + (activityCount * 90)
    }

    private func favoriteTeamMatches(_ team: FavoriteTeam, in match: LiveMatch) -> Bool {
        FavoriteTeamLiveMatcher.matchesLiveMatch(team, homeTeam: match.homeTeam, awayTeam: match.awayTeam)
    }

    private func favoriteTeamMatches(_ team: FavoriteTeam, in event: SportsEvent) -> Bool {
        FavoriteTeamLiveMatcher.matchesVenueEventTitle(team, title: event.title)
    }

    private var liveGamesLoadingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Checking live games…")
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(liveCardSurface(cornerRadius: 20, highlighted: false))
    }

    private var liveGamesEmptyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("No live games right now.")
                    .font(FGTypography.cardTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text(isBusinessLiveAudienceUser
                    ? "Check Crowd Momentum or open the map to find active watch spots."
                    : "Check Venues & Pickup Games Today or open the map to find watch spots.")
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button {
                    selectedTab = .discover
                } label: {
                    Label("Open Map", systemImage: "map.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Capsule(style: .continuous).fill(FGColor.accentGreen))
                }
                .buttonStyle(.plain)

                Button {
                    selectedTab = .calendar
                } label: {
                    Label("View Calendar", systemImage: "calendar")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.07))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(liveCardSurface(cornerRadius: 22, highlighted: true))
    }

    private func liveMatchRelatedItems(for match: LiveMatch, in items: [LiveFeedItem]) -> [LiveFeedItem] {
        items.filter { item in
            let eventText = normalizedLiveAudienceText([
                item.event.title,
                item.event.league,
                item.event.sport
            ].joined(separator: " "))
            let home = normalizedLiveAudienceText(match.homeTeam)
            let away = normalizedLiveAudienceText(match.awayTeam)
            let league = normalizedLiveAudienceText(match.league)
            let sport = normalizedLiveAudienceText(match.sport)

            return (!home.isEmpty && eventText.contains(home))
                || (!away.isEmpty && eventText.contains(away))
                || (!league.isEmpty && eventText.contains(league) && !sport.isEmpty && eventText.contains(sport))
        }
    }

    private func liveMergedSocialProfiles(from items: [LiveFeedItem]) -> [UserProfileRow] {
        var seen: Set<UUID> = []
        return items.flatMap(\.energy.socialPresenceProfiles).compactMap { profile in
            guard let id = profile.id, !seen.contains(id) else { return nil }
            seen.insert(id)
            return profile
        }
    }

    private func liveMatchSocialPresenceText(relatedItems: [LiveFeedItem]) -> String {
        let friendCount = relatedItems.reduce(0) { $0 + $1.energy.friendGoingCount }
        let goingCount = relatedItems.reduce(0) { $0 + $1.energy.goingCount }
        if friendCount > 0 {
            return friendCount == 1 ? "1 friend going nearby" : "\(friendCount) friends going nearby"
        }
        return goingCount == 1 ? "1 fan going nearby" : "\(goingCount) fans going nearby"
    }

    private func normalizedLiveAudienceText(_ raw: String) -> String {
        raw
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func liveFindVenuesDedupedRelatedItems(_ items: [LiveFeedItem]) -> [LiveFeedItem] {
        var seenBarIDs: Set<UUID> = []
        return items.filter { item in
            guard !seenBarIDs.contains(item.bar.id) else { return false }
            seenBarIDs.insert(item.bar.id)
            return true
        }
    }

    private func liveFindVenuesSortedRelatedItems(_ items: [LiveFeedItem]) -> (items: [LiveFeedItem], sortedByDistance: Bool) {
        let deduped = liveFindVenuesDedupedRelatedItems(items)
        guard let userCoordinate = viewModel.currentUserLocation,
              CLLocationCoordinate2DIsValid(userCoordinate) else {
            return (deduped, false)
        }
        let userLocation = CLLocation(latitude: userCoordinate.latitude, longitude: userCoordinate.longitude)
        let sorted = deduped.sorted { lhs, rhs in
            let lhsMeters = liveFindVenuesDistanceMeters(from: userLocation, to: lhs.bar.coordinate)
            let rhsMeters = liveFindVenuesDistanceMeters(from: userLocation, to: rhs.bar.coordinate)
            switch (lhsMeters, rhsMeters) {
            case let (l?, r?):
                if l == r { return lhs.bar.name.localizedCaseInsensitiveCompare(rhs.bar.name) == .orderedAscending }
                return l < r
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.bar.name.localizedCaseInsensitiveCompare(rhs.bar.name) == .orderedAscending
            }
        }
        return (sorted, true)
    }

    private func liveFindVenuesDistanceMeters(from userLocation: CLLocation, to coordinate: CLLocationCoordinate2D) -> Double? {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        return userLocation.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }

    private func liveFindVenuesDistanceText(for bar: BarVenue) -> String? {
        let trimmed = bar.distance.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        guard let userCoordinate = viewModel.currentUserLocation,
              CLLocationCoordinate2DIsValid(userCoordinate) else { return nil }
        let userLocation = CLLocation(latitude: userCoordinate.latitude, longitude: userCoordinate.longitude)
        guard let meters = liveFindVenuesDistanceMeters(from: userLocation, to: bar.coordinate) else { return nil }
        let miles = meters / 1609.34
        guard miles >= 0.05 else { return nil }
        if miles < 10 { return String(format: "%.1f mi", miles) }
        return String(format: "%.0f mi", miles)
    }

    private func liveFindVenuesFallbackButtonTitle(for sportType: LiveSportVisualType) -> String {
        switch sportType {
        case .soccer:
            return "Find Soccer Bars"
        case .basketball:
            return "Find Basketball Bars"
        case .hockey:
            return "Find Hockey Bars"
        case .baseball:
            return "Find Baseball Bars"
        case .nfl:
            return "Find Football Bars"
        case .tennis:
            return "Find Tennis Bars"
        case .badminton:
            return "Find Badminton Venues"
        case .golf:
            return "Find Golf Bars"
        case .breakdance:
            return "Find Break Dance Venues"
        case .ballet:
            return "Find Ballet Venues"
        case .formula1, .other:
            return "Open Map"
        }
    }

    private func liveFindVenuesDiscoverSportFilter(for sportType: LiveSportVisualType) -> String? {
        switch sportType {
        case .soccer:
            return "Soccer"
        case .basketball:
            return "NBA"
        case .hockey:
            return "NHL"
        case .baseball:
            return "Baseball"
        case .nfl:
            return "NFL"
        case .tennis:
            return "Tennis"
        case .badminton:
            return "badminton"
        case .golf:
            return "Golf"
        case .breakdance:
            return "Break Dance"
        case .ballet:
            return "Ballet"
        case .formula1, .other:
            return nil
        }
    }

    private func liveFindVenuesTapped(match: LiveMatch, relatedItems: [LiveFeedItem]) {
        let sorted = liveFindVenuesSortedRelatedItems(relatedItems)
#if DEBUG
        print("[LiveFindVenues] tapped match=\(match.id)")
        print("[LiveFindVenues] related_count=\(sorted.items.count)")
        print("[LiveFindVenues] sorted_by_distance=\(sorted.sortedByDistance)")
#endif
        if sorted.items.isEmpty {
            liveFindVenuesOpenDiscoverFallback(sportType: match.liveSportVisualType)
        } else {
            activeSheet = .watchSpots(LiveWatchSpotsPresentation(id: match.id, items: sorted.items))
        }
    }

    private func watchNearbyFavoriteTeam(
        _ item: FavoriteTeamLiveItem,
        matchRelatedItemsByMatchID: [String: [LiveFeedItem]]
    ) {
        if let match = item.primaryMatch {
            let relatedItems = matchRelatedItemsByMatchID[match.id] ?? []
            liveFindVenuesTapped(match: match, relatedItems: relatedItems)
            return
        }
        if viewModel.discoverMapContentMode != .venues {
            viewModel.clearDiscoverMapContentSelectionsWhenSwitching(to: .venues)
            viewModel.discoverMapContentMode = .venues
        }
        selectedTab = .discover
    }

    private func liveFindVenuesOpenDiscoverFallback(sportType: LiveSportVisualType) {
        let sportFilter = liveFindVenuesDiscoverSportFilter(for: sportType)
#if DEBUG
        print("[LiveFindVenues] fallback_sport_filter=\(sportFilter ?? "nil")")
#endif
        viewModel.discoverMapContentMode = .venues
        if let sportFilter {
            viewModel.sportChanged(to: sportFilter)
        }
        selectedTab = .discover
    }

    private func liveFindVenuesOpenVenue(_ item: LiveFeedItem) {
#if DEBUG
        print("[LiveFindVenues] opened_venue=\(item.bar.id.uuidString.lowercased()) name=\(item.bar.name)")
#endif
        activeSheet = nil
        openLiveItem(item)
    }

    @ViewBuilder
    private func liveWatchSpotsSheet(items: [LiveFeedItem]) -> some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(items) { item in
                        Button {
                            liveFindVenuesOpenVenue(item)
                        } label: {
                            liveWatchSpotsRow(item)
                        }
                        .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.985, hapticOnPress: true))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(FGAdaptiveSurface.sheetRoot.ignoresSafeArea())
            .navigationTitle("Watch spots for this game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        activeSheet = nil
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func liveWatchSpotsRow(_ item: LiveFeedItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SportArtworkIconView(sport: item.event.sport, diameter: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.bar.name)
                    .font(FGTypography.cardTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)

                if !item.bar.address.isEmpty {
                    Text(item.bar.address)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(2)
                }

                Text(item.event.title)
                    .font(FGTypography.metadata)
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let distance = liveFindVenuesDistanceText(for: item.bar) {
                Text(distance)
                    .font(FGTypography.metadata.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(liveCardSurface(cornerRadius: 18, highlighted: false))
    }

    private func liveMatchCard(_ match: LiveMatch, relatedItems: [LiveFeedItem]) -> some View {
        let sportType = match.liveSportVisualType
        let accent = sportType.catalogAccent
        let isFinalMatch = match.matchStatus == .fullTime
        let cardAccent = isFinalMatch ? FGColor.mutedText(colorScheme) : accent
        let catalogSportKey = sportType.sportFilterCatalogKey
        let watchSpotItems = liveFindVenuesSortedRelatedItems(relatedItems).items
        let hasWatchSpots = !watchSpotItems.isEmpty
        let findVenuesButtonTitle = hasWatchSpots
            ? "Find Venues"
            : liveFindVenuesFallbackButtonTitle(for: sportType)
        let socialProfiles = liveMergedSocialProfiles(from: relatedItems)
        let isSaved = viewModel.isProGameSaved(match)
        let featuredEvent = selectedFeaturedEvent(for: match)
        let competitionLine = liveMatchCompetitionLine(for: match)
        let countryChip = liveMatchCountryChipText(for: match)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ProGameSportBadgeView(
                    sportType: sportType,
                    diameter: 42,
                    featuredEvent: featuredEvent,
                    featuredEventSlug: match.featuredEventSlug
                )

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        liveStatusPill(match, accent: cardAccent)

                        // Sport-only chip (not league) so competition can use its own line.
                        ProGameLeagueChip(
                            sportType: sportType,
                            featuredEvent: nil,
                            league: ""
                        )

                        if !countryChip.isEmpty {
                            Text(countryChip)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(FGColor.secondaryText(colorScheme).opacity(colorScheme == .dark ? 0.16 : 0.08))
                                )
                                .lineLimit(1)
                                .layoutPriority(1)
                        }

                        Spacer(minLength: 0)
                    }

                    if !competitionLine.isEmpty {
                        Text(competitionLine)
                            .font(FGTypography.caption.weight(.semibold))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(2)
                            .minimumScaleFactor(0.88)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                liveProGameSaveButton(match, isSaved: isSaved, accent: accent)
                    .layoutPriority(2)
            }

            ProGameScoreBlock(
                awayTeam: match.awayTeam,
                homeTeam: match.homeTeam,
                awayScore: match.scoreAway,
                homeScore: match.scoreHome,
                awayBadgeURL: match.awayTeamBadgeURL,
                homeBadgeURL: match.homeTeamBadgeURL,
                source: "Live",
                isFinal: isFinalMatch,
                isLive: match.matchStatus.isHappeningNow,
                accentColor: cardAccent,
                style: ProGameScoreboardStyle(
                    scoreFont: .system(size: 24, weight: .black, design: .rounded).monospacedDigit(),
                    separatorFont: .system(size: 18, weight: .bold, design: .rounded),
                    teamNameFont: .system(size: 13, weight: .semibold, design: .rounded),
                    emblemSize: 24
                ),
                timelineSummary: match.resolvedGoalDisplaySummary,
                cardTimelineSummary: match.resolvedCardTimelineSummary,
                gameId: SavedProGame.stableKey(for: match),
                showsFramedFinalBackground: isFinalMatch,
                flagSource: "Live"
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            if canShowPersonalLiveSections && !socialProfiles.isEmpty {
                HStack(spacing: 8) {
                    GoingAvatarStack(profiles: socialProfiles, viewerUserID: viewModel.currentUserAuthId, diameter: 24)
                    Text(liveMatchSocialPresenceText(relatedItems: relatedItems))
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 10) {
                Text(formattedLocalGameStartTime(match.startTime))
                    .font(FGTypography.metadata)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)

                Spacer(minLength: 8)

                if isFinalMatch {
                    Text("Game Final")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(FGColor.mutedText(colorScheme).opacity(colorScheme == .dark ? 0.14 : 0.08))
                        )
                } else {
                    Button {
                        liveFindVenuesTapped(match: match, relatedItems: relatedItems)
                    } label: {
                        Text(findVenuesButtonTitle)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule(style: .continuous).fill(accent.opacity(colorScheme == .dark ? 0.16 : 0.10)))
                    }
                    .buttonStyle(.plain)
                }
            }

            if match.supportsProGamePredictions && isSaved {
                liveProGamePredictionFooter(for: match)
            }
        }
        .padding(12)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(liveCardSurface(cornerRadius: 22, highlighted: match.matchStatus.isHappeningNow))
        .overlay {
            if match.matchStatus.isHappeningNow {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(FGColor.dangerRed.opacity(colorScheme == .dark ? 0.34 : 0.22), lineWidth: 1)
            } else {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(cardAccent.opacity(colorScheme == .dark ? 0.46 : 0.28), lineWidth: 1)
            }
        }
        .onAppear {
#if DEBUG
            let visual = sportType.catalogVisual
            print("[LiveSportIconMapping] id=\(match.id) normalized=\(match.sport) catalogKey=\(catalogSportKey) systemImage=\(visual.systemImage) label=\(sportType.filterChipLabel)")
            print("[LiveSportDetected] id=\(match.id) presentationType=\(sportType.rawValue) accent=\(accent)")
#endif
            logLiveMatchScoringEventDebug(match)
        }
        .onTapGesture {
            activeSheet = .matchDetail(match)
        }
    }

    private func liveProGamePredictionFooter(for match: LiveMatch) -> some View {
        let game = SavedProGame.forPredictions(match: match, savedGames: viewModel.savedProGames)
        return ProGamePredictionFooterRow(
            game: game,
            summary: viewModel.proGamePredictionSummaries[game.stableKey]
        ) {
            activeSheet = .proGamePrediction(ProGamePredictionSheetContext(game: game))
        }
        .task(id: game.stableKey) {
            await viewModel.prefetchProGamePredictionSummaries(for: [game])
        }
    }

    private func liveProGameSaveButton(_ match: LiveMatch, isSaved: Bool, accent: Color) -> some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                viewModel.toggleSavedProGame(match)
            }
        } label: {
            Image(systemName: isSaved ? "heart.fill" : "heart")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(isSaved ? Color.red.opacity(0.95) : accent)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill((isSaved ? Color.red : accent).opacity(colorScheme == .dark ? 0.18 : 0.10))
                )
                .overlay {
                    Circle()
                        .strokeBorder((isSaved ? Color.red : accent).opacity(colorScheme == .dark ? 0.40 : 0.24), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSaved ? L10n.t("unsave_pro_sports_game_a11y") : L10n.t("save_pro_sports_game_a11y"))
    }

    private func liveFeedNativeAdCard(slotIndex: Int) -> some View {
        CompactNativeAdCard(
            placement: "live.feed",
            hostTabRaw: "live",
            slotIndex: slotIndex,
            layoutWidth: liveFeedNativeAdLayoutWidth,
            prefersLightChrome: false,
            animatesLoadState: true
        )
        .frame(maxWidth: .infinity)
        .frame(height: CompactNativeAdLayout.preferredHeight)
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func updateLiveFeedNativeAdLayoutWidth(_ width: CGFloat) {
        guard width > 0, abs(liveFeedNativeAdLayoutWidth - width) > 0.5 else { return }
        liveFeedNativeAdLayoutWidth = max(280, width)
    }

    @ViewBuilder
    private func liveVenueLine(_ match: LiveMatch) -> some View {
        if let venueText = liveVenueDisplayText(for: match) {
            liveVenueLineContent(venueText)
        }
    }

    private func liveVenueLineContent(_ venueText: String) -> some View {
        HStack(spacing: 6) {
            Text("📍")
                .font(.caption2.weight(.bold))

            Text(venueText)
                .font(FGTypography.metadata)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func liveBroadcastLine(_ match: LiveMatch, accent: Color) -> some View {
        if let tvDisplayText = match.tvDisplayText {
            HStack(spacing: 6) {
                Image(systemName: "tv.fill")
                    .font(.caption2.weight(.bold))
                Text(tvDisplayText)
                    .font(FGTypography.metadata.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(accent)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func logLiveMatchScoringEventDebug(_ match: LiveMatch) {
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

    private func liveVenueDisplayText(for match: LiveMatch) -> String? {
        let venue = match.venueName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !venue.isEmpty else { return nil }
        let city = match.venueCity?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return city.isEmpty ? venue : "\(venue) • \(city)"
    }

    /// Full competition/league line for Live cards (country is shown separately).
    private func liveMatchCompetitionLine(for match: LiveMatch) -> String {
        let candidates = [
            match.league,
            match.sourceLeagueName,
            match.leagueAlternate,
            match.eventName
        ]
        for raw in candidates {
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    private func liveMatchCountryChipText(for match: LiveMatch) -> String {
        let country = match.leagueCountry?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !country.isEmpty else { return "" }
        return CountryFlagHelper.compactCountryChipText(for: country, source: "Live")
    }

    /// Legacy combined line kept for any remaining call sites.
    private func liveMatchLeagueCompetitionText(for match: LiveMatch) -> String {
        let league = liveMatchCompetitionLine(for: match)
        let countryText = liveMatchCountryChipText(for: match)
        guard !countryText.isEmpty else { return league }
        return league.isEmpty ? countryText : "\(countryText) • \(league)"
    }

    private func liveStatusPill(_ match: LiveMatch, accent: Color) -> some View {
        let statusTint = match.matchStatus.isHappeningNow ? FGColor.dangerRed : accent
        return HStack(spacing: 5) {
            Circle()
                .fill(match.matchStatus.isHappeningNow ? FGColor.dangerRed : statusTint.opacity(0.75))
                .frame(width: 5, height: 5)
                .shadow(color: statusTint.opacity(0.55), radius: match.matchStatus.isHappeningNow ? 4 : 0)

            Text(liveStatusText(match))
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(statusTint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule(style: .continuous).fill(statusTint.opacity(colorScheme == .dark ? 0.18 : 0.11)))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(statusTint.opacity(0.26), lineWidth: 1)
        }
        .accessibilityLabel(liveStatusText(match))
        .onAppear {
            guard match.matchStatus.isHappeningNow, isLiveTabSelected else { return }
            logLiveBadgeDebug()
        }
    }

    private func liveStatusText(_ match: LiveMatch) -> String {
        if match.matchStatus == .fullTime {
            return "FINAL"
        }
        if match.matchStatus == .halfTime {
            return "HT"
        }
        if match.matchStatus == .scheduled {
            // Defensive UI only: do not confidently show TODAY when the row looks contradictory
            // (past start + score/progress) while still classified as scheduled. Sectioning stays
            // status-driven; this avoids a misleading TODAY badge until status mapping catches up.
            if isContradictoryScheduledLivePresentation(match) {
#if DEBUG
                print(
                    "[LiveStatusAudit] badgeGuard id=\(match.id) rawStatus=\(match.rawMatchStatus ?? "nil") " +
                    "clock=\(match.liveClockText ?? "nil") score=\(match.scoreAway)-\(match.scoreHome) " +
                    "badge=UPCOMING (avoid TODAY)"
                )
#endif
                return "UPCOMING"
            }
            return Calendar.current.isDate(match.startTime, inSameDayAs: liveCalendarToday) ? "TODAY" : "UPCOMING"
        }
        if let minute = match.minute {
            return "LIVE \(minute)'"
        }
        return "LIVE"
    }

    /// Scheduled + materially past start + (nonzero score or baseball progress hint).
    /// Does not invent Live/Final or move sections — badge-only softener.
    private func isContradictoryScheduledLivePresentation(_ match: LiveMatch) -> Bool {
        guard match.matchStatus == .scheduled else { return false }
        guard match.startTime.timeIntervalSinceNow < -5 * 60 else { return false }
        let hasNonzeroScore = match.scoresAreAvailable && (match.scoreHome > 0 || match.scoreAway > 0)
        if hasNonzeroScore { return true }
        return MatchStatus.looksLikeBaseballInningProgress(match.liveClockText)
            || MatchStatus.looksLikeBaseballInningProgress(match.rawMatchStatus)
    }

    private func updateLiveAutoRefreshForCurrentState(scheduleActivationRefresh: Bool) {
        if shouldAutoRefreshLiveMatches {
            startLiveAutoRefresh()
            if scheduleActivationRefresh {
                scheduleDebouncedLiveActivationRefresh()
            }
        } else {
            liveActivationRefreshTask?.cancel()
            liveActivationRefreshTask = nil
            stopLiveAutoRefresh()
        }
    }

    private func scheduleDebouncedLiveActivationRefresh() {
        guard shouldAutoRefreshLiveMatches else { return }
        liveActivationRefreshTask?.cancel()
        liveActivationRefreshTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: Self.liveActivationDebounceNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled, shouldAutoRefreshLiveMatches else { return }
            TabPerf.refreshStarted(name: "liveMatches")
            await viewModel.refreshLiveMatchesForLiveTabActivation(forceRefresh: false)
            liveActivationRefreshTask = nil
        }
    }

    private func startLiveAutoRefresh() {
        guard liveAutoRefreshTask == nil else { return }

        liveAutoRefreshTask = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.liveAutoRefreshIntervalNanoseconds)
                } catch {
                    break
                }

                guard !Task.isCancelled else { break }
                guard shouldAutoRefreshLiveMatches else {
                    stopLiveAutoRefresh()
                    break
                }
                guard !viewModel.isLoadingLiveMatches else { continue }

                LiveActivationPerf.timerTick()
                refreshLiveMatches(forceRefresh: false)
#if DEBUG
                print("[PerfPhase1] liveAutoRefresh forceRefresh=false reason=timer")
#endif
            }
        }
    }

    private func stopLiveAutoRefresh() {
        liveAutoRefreshTask?.cancel()
        liveAutoRefreshTask = nil
    }

    private func refreshLiveMatches(forceRefresh: Bool) {
        Task {
            await viewModel.refreshLiveMatchesForLiveTab(forceRefresh: forceRefresh)
        }
    }

    @MainActor
    private func performManualLiveRefresh() async {
#if DEBUG
        print("[LiveDebug] manualRefreshStarted")
#endif
        await viewModel.refreshLiveMatchesForLiveTab(forceRefresh: true)
#if DEBUG
        print("[LiveDebug] manualRefreshFinished")
#endif
    }

    private enum LiveVenuesPickupRow: Identifiable {
        case venue(LiveFeedItem)
        case pickup(PickupGameRow)

        var id: String {
            switch self {
            case .venue(let item):
                return "venue-\(item.id)"
            case .pickup(let row):
                return "pickup-\(row.id.uuidString)"
            }
        }

        var isLiveNow: Bool {
            switch self {
            case .venue(let item):
                // Deprecated for sports LIVE — use sports-canonical status at call site.
                return item.energy.isLiveNow
            case .pickup(let row):
                return row.hasPickupGameStarted()
            }
        }

    }

    private func liveVenuesPickupRowIsInProgress(_ row: LiveVenuesPickupRow) -> Bool {
        switch row {
        case .venue(let item):
            return resolveVenueEventMatchStatus(for: item).isLive
        case .pickup(let pickup):
            return LivePickupCardModelBuilder.build(row: pickup).isInProgress
        }
    }

    private func liveVenuesAndPickupTodaySection(rows: [LiveVenuesPickupRow]) -> some View {
        let languageCode = liveNowLanguageCode
        let title = L10n.t("live_supporting_venues_title", languageCode: languageCode)
        let subtitle = L10n.t("live_supporting_venues_subtitle", languageCode: languageCode)
        let statusText = liveSupportingTodayCountText(rows.count, languageCode: languageCode)
        return liveSupportingCompactSection(
            kind: .venuesPickup,
            title: title,
            subtitle: subtitle,
            statusText: statusText,
            isEmpty: rows.isEmpty,
            showsBottomDivider: true,
            accessibilityLabel: liveSupportingRowAccessibilityLabel(
                title: title,
                statusText: statusText,
                subtitle: subtitle,
                languageCode: languageCode
            )
        ) {
            let liveRows = rows.filter(liveVenuesPickupRowIsInProgress)
            let otherRows = rows.filter { !liveVenuesPickupRowIsInProgress($0) }
            VStack(alignment: .leading, spacing: 12) {
                if !liveRows.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(liveRows) { row in
                                liveVenuesPickupCompactCard(row)
                                    .frame(width: 288)
                            }
                        }
                        .padding(.horizontal, 1)
                        .padding(.vertical, 2)
                    }
                    .scrollClipDisabled()
                }
                if !otherRows.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(otherRows) { row in
                            switch row {
                            case .venue(let item):
                                liveVenuesPickupVenueRow(item)
                            case .pickup(let pickup):
                                liveVenuesPickupPickupRow(pickup)
                            }
                        }
                    }
                }
            }
        }
        .task(id: rows.map(\.id).joined(separator: "|")) {
            let creatorIds = Set(rows.compactMap { row -> UUID? in
                if case .pickup(let pickup) = row { return pickup.creator_user_id }
                return nil
            })
            guard !creatorIds.isEmpty else { return }
            await viewModel.loadPickupCreatorProfilesIfNeeded(creatorUserIds: creatorIds)
        }
    }

    @ViewBuilder
    private func liveVenuesPickupCompactCard(_ row: LiveVenuesPickupRow) -> some View {
        switch row {
        case .venue(let item):
            liveVenuesPickupVenueRow(item, compact: true)
        case .pickup(let pickup):
            liveVenuesPickupPickupRow(pickup, compact: true)
        }
    }

    private func liveVenueEventCardModel(for item: LiveFeedItem) -> LiveVenueEventCardModel {
        let linked = linkedLiveMatch(for: item)
        let row = viewModel.cachedVenueEventRow(for: item.bar, gameTitle: item.event.title)
        let thumbnail = ImageDisplayURL.forList(
            thumbnail: item.bar.coverPhotoThumbnailURL,
            full: item.bar.coverPhotoURL
        )
        let bridge = LiveScreenLiveFeedItemBridge(
            id: item.id,
            eventTitle: item.event.title,
            eventDate: linked?.startTime ?? item.event.date,
            sport: item.event.sport,
            venueName: item.bar.name,
            homeTeam: row?.home_team,
            awayTeam: row?.away_team,
            goingCount: item.energy.goingCount,
            commentCount: canShowPersonalLiveSections ? item.energy.commentCount : 0,
            friendGoingCount: canShowPersonalLiveSections ? item.energy.friendGoingCount : 0,
            vibeCount: item.vibeCount,
            energyStartsSoon: item.energy.startsSoon,
            thumbnailURLString: thumbnail
        )
        return LiveVenueEventCardModelBuilder.build(
            item: bridge,
            linkedMatch: linked,
            venueRowAdminStatus: row?.admin_status,
            languageCode: L10n.normalizedLanguageCode(appLanguageRaw),
            formattedStartTime: { formattedLocalGameStartTime($0) }
        )
    }

    private func liveVenuesPickupVenueRow(_ item: LiveFeedItem, compact: Bool = false) -> some View {
        let model = liveVenueEventCardModel(for: item)
        return Button {
            openLiveItem(item)
        } label: {
            LiveVenueEventRichCard(model: model, compact: compact)
        }
        .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.985, hapticOnPress: true))
        .accessibilityHint(L10n.t("live_open_venue_hint", languageCode: L10n.normalizedLanguageCode(appLanguageRaw)))
    }

    private func liveVenuesPickupPickupRow(_ row: PickupGameRow, compact: Bool = false) -> some View {
        let languageCode = L10n.normalizedLanguageCode(appLanguageRaw)
        let model = LivePickupCardModelBuilder.build(row: row, languageCode: languageCode)
        return LivePickupRichCard(
            viewModel: viewModel,
            model: model,
            compact: compact,
            relevanceLabel: isPickupUserRelevant(row) ? userPickupRelevanceLabel(row) : nil,
            onOpenDetails: { openPickupGameFromLive(row) }
        )
    }

    private func openPickupGameFromLive(_ row: PickupGameRow) {
        if viewModel.discoverMapContentMode != .pickupGames {
            viewModel.clearDiscoverMapContentSelectionsWhenSwitching(to: .pickupGames)
            viewModel.discoverMapContentMode = .pickupGames
        }
        if viewModel.discoverPickupSubMode != .games {
            viewModel.discoverPickupSubMode = .games
        }
        viewModel.calendarTabGameFilter = .pickupGames
        viewModel.requestDiscoverFocusForPickupGame(id: row.id, snapshot: row)
        selectedTab = .discover
    }

    private func venuesAndPickupTodayRows(from rankedItems: [LiveFeedItem]) -> [LiveVenuesPickupRow] {
        var rows: [LiveVenuesPickupRow] = []
        var seenVenueKeys: Set<String> = []

        for item in rankedItems {
            guard venuesAndPickupVenueQualifies(item) else { continue }
            guard !seenVenueKeys.contains(item.id) else { continue }
            seenVenueKeys.insert(item.id)
            rows.append(.venue(item))
        }

        for pickup in pickupGamesForLiveToday() {
            rows.append(.pickup(pickup))
        }

        return rows
            .sorted { lhs, rhs in
                let l = venuesAndPickupSortScore(lhs)
                let r = venuesAndPickupSortScore(rhs)
                if l == r { return lhs.id < rhs.id }
                return l > r
            }
            .prefix(16)
            .map { $0 }
    }

    private func venuesAndPickupSortScore(_ row: LiveVenuesPickupRow) -> Int {
        switch row {
        case .venue(let item):
            let sportsLiveBoost = resolveVenueEventMatchStatus(for: item).isLive ? 20_000 : 0
            return item.score
                + sportsLiveBoost
                + (item.energy.startsSoon ? 5_000 : 0)
        case .pickup(let pickup):
            let userBoost = isPickupUserRelevant(pickup) ? 8_000 : 0
            let liveBoost = LivePickupCardModelBuilder.build(row: pickup).isInProgress ? 20_000 : 0
            return userBoost + liveBoost + pickup.approvedJoinCount * 140
        }
    }

    private func venuesAndPickupVenueQualifies(_ item: LiveFeedItem) -> Bool {
        let status = resolveVenueEventMatchStatus(for: item)
        if status.isLive || item.energy.startsSoon { return true }
        if case .startingSoon = status { return true }
        if item.energy.goingCount > 0 { return true }
        if canShowPersonalLiveSections && item.energy.friendGoingCount > 0 { return true }
        if canShowPersonalLiveSections && item.energy.commentCount > 0 { return true }
        if item.vibeCount > 0 { return true }
        if status.isFinal { return true }
        return false
    }

    private func pickupGamesForLiveToday() -> [PickupGameRow] {
        let cal = Calendar.current
        return viewModel.pickupGamesForDiscoverMap.filter { row in
            guard let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else { return false }
            return cal.isDate(start, inSameDayAs: liveCalendarToday)
        }
    }

    private func isPickupUserRelevant(_ row: PickupGameRow) -> Bool {
        guard let me = viewModel.currentUserAuthId else { return false }
        if row.creator_user_id == me { return true }
        if viewModel.myPickupGamesForSettings.contains(where: { $0.id == row.id }) { return true }
        if viewModel.myPickupGameJoinRequestCards.contains(where: { $0.pickupGameId == row.id }) { return true }
        return false
    }

    private func userPickupRelevanceLabel(_ row: PickupGameRow) -> String {
        guard let me = viewModel.currentUserAuthId else { return "Your game" }
        if row.creator_user_id == me { return "You host" }
        if viewModel.myPickupGamesForSettings.contains(where: { $0.id == row.id }) { return "You host" }
        if viewModel.myPickupGameJoinRequestCards.contains(where: { $0.pickupGameId == row.id }) { return "You joined" }
        return "Your game"
    }

    private func pickupStartDisplay(for row: PickupGameRow) -> String {
        guard let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else { return "Today" }
        return formattedLocalGameStartTime(start)
    }

    private func liveFriendsSection(items: [LiveFeedItem]) -> some View {
        let languageCode = liveNowLanguageCode
        let title = L10n.t("live_supporting_friends_title", languageCode: languageCode)
        let subtitle = L10n.t("live_supporting_friends_subtitle", languageCode: languageCode)
        let statusText = liveSupportingPlansCountText(items.count, languageCode: languageCode)
        return liveSupportingCompactSection(
            kind: .friendsGoing,
            title: title,
            subtitle: subtitle,
            statusText: statusText,
            isEmpty: items.isEmpty,
            showsBottomDivider: true,
            accessibilityLabel: liveSupportingRowAccessibilityLabel(
                title: title,
                statusText: statusText,
                subtitle: subtitle,
                languageCode: languageCode
            )
        ) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(items) { item in
                        liveFriendCompactCard(item)
                            .frame(width: 260)
                    }
                }
                .padding(.horizontal, 1)
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
        }
    }

    private func liveCrowdBuildingSection(items: [LiveCrowdMomentum]) -> some View {
        let languageCode = liveNowLanguageCode
        let title = isBusinessLiveAudienceUser
            ? L10n.t("live_supporting_crowd_momentum_title", languageCode: languageCode)
            : L10n.t("live_supporting_crowd_title", languageCode: languageCode)
        let subtitle = isBusinessLiveAudienceUser
            ? L10n.t("live_supporting_crowd_momentum_subtitle", languageCode: languageCode)
            : L10n.t("live_supporting_crowd_subtitle", languageCode: languageCode)
        let statusText = liveSupportingActiveCountText(items.count, languageCode: languageCode)
        return liveSupportingCompactSection(
            kind: .crowdBuilding,
            title: title,
            subtitle: subtitle,
            statusText: statusText,
            isEmpty: items.isEmpty,
            showsBottomDivider: false,
            accessibilityLabel: liveSupportingRowAccessibilityLabel(
                title: title,
                statusText: statusText,
                subtitle: subtitle,
                languageCode: languageCode
            )
        ) {
            VStack(spacing: 10) {
                ForEach(items) { momentum in
                    liveCrowdBuildingCard(momentum)
                }
            }
        }
    }

    private func liveCrowdBuildingCard(_ momentum: LiveCrowdMomentum) -> some View {
        let item = momentum.item
        return Button {
            openLiveItem(item)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    SportArtworkIconView(sport: item.event.sport, diameter: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.event.title)
                            .font(FGTypography.cardTitle)
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(2)
                        Text(item.bar.name)
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    if momentum.goingCount > 0 {
                        crowdBuildingMetricChip(
                            icon: "person.2.fill",
                            label: momentum.goingCount == 1 ? "1 going" : "\(momentum.goingCount) going"
                        )
                    }
                    if momentum.chatCount > 0 {
                        crowdBuildingMetricChip(
                            icon: "bubble.left.and.bubble.right.fill",
                            label: momentum.chatCount == 1 ? "1 chat" : "\(momentum.chatCount) chat"
                        )
                    }
                    if let topVibe = momentum.topVibeLabel {
                        crowdBuildingMetricChip(icon: "flame.fill", label: topVibe, accent: FGColor.dangerRed)
                    }
                    if momentum.homeCrowdFanCount > 0 {
                        crowdBuildingMetricChip(
                            icon: "shield.lefthalf.filled",
                            label: momentum.homeCrowdFanCount == 1 ? "Home Venue" : "Home Venue · \(momentum.homeCrowdFanCount)",
                            accent: Color(red: 0.58, green: 0.36, blue: 0.94)
                        )
                    }
                }

                if momentum.showsFriendAvatars {
                    HStack(spacing: 8) {
                        GoingAvatarStack(
                            profiles: item.energy.socialPresenceProfiles,
                            viewerUserID: viewModel.currentUserAuthId,
                            diameter: 26
                        )
                        Text(item.energy.socialPresenceLabel ?? "Fans going")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                    }
                }
            }
            .padding(14)
            .background(liveCardSurface(cornerRadius: 20, highlighted: false))
        }
        .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.985, hapticOnPress: true))
    }

    private func crowdBuildingMetricChip(icon: String, label: String, accent: Color = FGColor.accentGreen) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule(style: .continuous).fill(accent.opacity(colorScheme == .dark ? 0.16 : 0.10)))
    }

    private func liveSupportingTodayCountText(_ count: Int, languageCode: String) -> String {
        String(format: L10n.t("live_supporting_today_count_format", languageCode: languageCode), Int64(count))
    }

    private func liveSupportingPlansCountText(_ count: Int, languageCode: String) -> String {
        String(format: L10n.t("live_supporting_plans_count_format", languageCode: languageCode), Int64(count))
    }

    private func liveSupportingActiveCountText(_ count: Int, languageCode: String) -> String {
        String(format: L10n.t("live_supporting_active_count_format", languageCode: languageCode), Int64(count))
    }

    private func liveSupportingRowAccessibilityLabel(
        title: String,
        statusText: String,
        subtitle: String,
        languageCode: String
    ) -> String {
        String(
            format: L10n.t("live_supporting_row_a11y_format", languageCode: languageCode),
            title,
            statusText,
            subtitle
        )
    }

    /// Compact Apple-style summary row for Live supporting sections (Venues, Friends, Crowd).
    private func liveSupportingCompactSection<Content: View>(
        kind: LivePanelKind,
        title: String,
        subtitle: String,
        statusText: String,
        isEmpty: Bool,
        showsBottomDivider: Bool,
        accessibilityLabel: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let accent = kind.accentColor(colorScheme: colorScheme)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: isEmpty ? 0 : 10) {
                // Full-row hit target absorbs taps so they cannot fall through to UIKit ad hosts.
                Button(action: {}) {
                    HStack(alignment: .center, spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(accent.opacity(colorScheme == .dark ? 0.22 : 0.14))
                                .frame(width: 36, height: 36)
                            Image(systemName: kind.icon)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(accent)
                        }
                        .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }

                        Spacer(minLength: 8)

                        Text(statusText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(accent.opacity(colorScheme == .dark ? 0.18 : 0.12))
                            )
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityHidden(true)

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(FGColor.mutedText(colorScheme))
                            .opacity(isEmpty ? 0.45 : 1)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityAddTraits(.isHeader)

                if !isEmpty {
                    content()
                }
            }
            .padding(.vertical, 6)

            if showsBottomDivider {
                Divider()
                    .overlay(FGColor.mutedText(colorScheme).opacity(colorScheme == .dark ? 0.35 : 0.22))
                    .padding(.top, 2)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .zIndex(2)
    }

    private func liveCollapsiblePanelSection<Content: View>(
        kind: LivePanelKind,
        title: String,
        liveCount: Int,
        todayCount: Int,
        subtitle: String,
        subtitleUsesSubheadline: Bool = false,
        accessibilityLabelText: String? = nil,
        isExpanded: Bool,
        toggle: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let accent = kind.accentColor(colorScheme: colorScheme)
        let liveLabel = liveHeaderLiveCountLabel(liveCount)
        let todayLabel = liveHeaderTodayCountLabel(todayCount)
        return VStack(alignment: .leading, spacing: 14) {
            Button(action: toggle) {
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(accent.opacity(colorScheme == .dark ? 0.22 : 0.14))
                            .frame(width: 40, height: 40)
                        Image(systemName: kind.icon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(accent)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Text(title)
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                                .lineLimit(2)
                                .minimumScaleFactor(0.82)
                                .fixedSize(horizontal: false, vertical: true)
                            if liveCount > 0 {
                                Circle()
                                    .fill(FGColor.dangerRed)
                                    .frame(width: 8, height: 8)
                                    .accessibilityHidden(true)
                            }
                        }
                        // Compact secondary summary: "1 Live • 20 Today" (not "1/20").
                        HStack(spacing: 5) {
                            Text(liveLabel)
                                .foregroundStyle(FGColor.dangerRed)
                            Text("•")
                                .foregroundStyle(FGColor.secondaryText(colorScheme).opacity(0.85))
                            Text(todayLabel)
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                        }
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .accessibilityHidden(true)

                        Text(subtitle)
                            .font(subtitleUsesSubheadline ? .subheadline.weight(.medium) : FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(subtitleUsesSubheadline ? 1 : 3)
                            .minimumScaleFactor(0.78)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(accent)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isExpanded)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                accessibilityLabelText
                    ?? "\(title), \(liveHeaderLiveCountAccessibilityPhrase(liveCount)), \(liveHeaderTodayCountAccessibilityPhrase(todayCount))"
            )
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Toggles the live games section")

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    content()
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(kind.panelFill(colorScheme: colorScheme))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(kind.panelStroke(colorScheme: colorScheme), lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func liveSectionEmptyState(_ message: String) -> some View {
        Text(message)
            .font(FGTypography.caption)
            .foregroundStyle(FGColor.mutedText(colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }

    private func liveFriendCompactCard(_ item: LiveFeedItem) -> some View {
        Button {
            openLiveItem(item)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                GoingAvatarStack(
                    profiles: item.energy.socialPresenceProfiles,
                    viewerUserID: viewModel.currentUserAuthId,
                    diameter: 32
                )
                Text(item.energy.socialPresenceLabel ?? item.energy.friendPresenceLabel ?? "Friends going")
                    .font(FGTypography.cardTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(1)
                Text("\(item.event.title) · \(item.bar.name)")
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(2)
                if item.energy.isLiveNow {
                    livePillBadge
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(liveCardSurface(cornerRadius: 18, highlighted: item.energy.isLiveNow))
        }
        .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.985, hapticOnPress: true))
    }

    private func liveHappeningCard(_ item: LiveFeedItem) -> some View {
        Button {
            openLiveItem(item)
        } label: {
            let profiles = item.energy.socialPresenceProfiles
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    SportArtworkIconView(sport: item.event.sport, diameter: 42)
                    Spacer(minLength: 12)
                    liveDot
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(item.event.title)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)

                    Text(item.bar.name)
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }

                liveTokenWrap(item, limit: 4)

                if canShowPersonalLiveSections && !profiles.isEmpty {
                    liveAvatarProof(item)
                } else {
                    Text(liveOperationalSubtitle(for: item))
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(2)
                }
            }
            .padding(16)
            .frame(width: 258, alignment: .topLeading)
            .frame(minHeight: 210, alignment: .topLeading)
            .background(liveCardSurface(cornerRadius: 24, highlighted: true))
            .overlay(alignment: .bottomTrailing) {
                liveScorePill(item.score)
                    .padding(14)
            }
        }
        .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.985, hapticOnPress: true))
    }

    private func liveStartingSoonRow(_ item: LiveFeedItem) -> some View {
        Button {
            openLiveItem(item)
        } label: {
            HStack(spacing: 12) {
                VStack(spacing: 2) {
                    Text(item.energy.minutesUntilStart.map { "\($0)" } ?? "Soon")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.accentGreen)
                    if item.energy.minutesUntilStart != nil {
                        Text("min")
                            .font(FGTypography.metadata)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                }
                .frame(width: 50)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.event.title)
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                    Text("\(item.bar.name) · \(viewModel.displayTime(for: item.event))")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
                liveInlineTokens(item)
            }
            .padding(14)
            .background(liveCardSurface(cornerRadius: 20, highlighted: false))
        }
        .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.985, hapticOnPress: true))
    }

    private func liveFriendRow(_ item: LiveFeedItem) -> some View {
        Button {
            openLiveItem(item)
        } label: {
            HStack(spacing: 12) {
                GoingAvatarStack(profiles: item.energy.socialPresenceProfiles, viewerUserID: viewModel.currentUserAuthId)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.energy.socialPresenceLabel ?? item.energy.friendPresenceLabel ?? "\(item.energy.friendGoingCount) friends going")
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                    Text("\(item.event.title) · \(item.bar.name)")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            }
            .padding(14)
            .background(liveCardSurface(cornerRadius: 20, highlighted: false))
        }
        .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.985, hapticOnPress: true))
    }

    private func liveEmptyCard(_ message: String) -> some View {
        Text(message)
            .font(FGTypography.caption)
            .foregroundStyle(FGColor.secondaryText(colorScheme))
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(liveCardSurface(cornerRadius: 20, highlighted: false))
    }

    private func liveQuietEmptyLine(_ message: String) -> some View {
        Text(message)
            .font(FGTypography.caption)
            .foregroundStyle(FGColor.mutedText(colorScheme))
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func liveCardSurface(cornerRadius: CGFloat, highlighted: Bool) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(liveCardFill(highlighted: highlighted))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        highlighted
                            ? FGColor.dangerRed.opacity(colorScheme == .dark ? 0.30 : 0.20)
                            : FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 1 : 0.75),
                        lineWidth: 1
                    )
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.07), radius: highlighted ? 18 : 10, y: highlighted ? 10 : 5)
            .shadow(color: FGColor.dangerRed.opacity(highlighted ? (colorScheme == .dark ? 0.12 : 0.06) : 0), radius: 22, y: 0)
    }

    private func liveCardFill(highlighted: Bool) -> Color {
        if highlighted {
            return colorScheme == .dark
                ? Color(red: 0.20, green: 0.07, blue: 0.07).opacity(0.42)
                : Color(red: 1.0, green: 0.96, blue: 0.96)
        }
        return colorScheme == .dark ? Color.white.opacity(0.075) : Color.white.opacity(0.78)
    }

    private var livePillBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(FGColor.dangerRed)
                .frame(width: 6, height: 6)
            Text("LIVE")
                .font(.system(size: 10, weight: .bold, design: .rounded))
        }
        .foregroundStyle(FGColor.dangerRed)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule(style: .continuous).fill(FGColor.dangerRed.opacity(colorScheme == .dark ? 0.16 : 0.10)))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(FGColor.dangerRed.opacity(0.24), lineWidth: 1)
        }
    }

    private var liveDot: some View {
        livePillBadge
        .onAppear {
            logLiveBadgeDebug()
        }
    }

    private func liveTokenWrap(_ item: LiveFeedItem, limit: Int) -> some View {
        FGWrappingLayout(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(Array(liveEnergyTokens(for: item).prefix(limit)), id: \.self) { token in
                liveToken(token)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func liveInlineTokens(_ item: LiveFeedItem) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(liveEnergyTokens(for: item).prefix(2)), id: \.self) { token in
                liveToken(token)
            }
        }
    }

    private func liveToken(_ token: String) -> some View {
        Text(token)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(liveTokenTint(token))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(liveTokenTint(token).opacity(colorScheme == .dark ? 0.16 : 0.10)))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(liveTokenTint(token).opacity(0.24), lineWidth: 1)
            }
    }

    private func liveAvatarProof(_ item: LiveFeedItem) -> some View {
        HStack(spacing: 8) {
            GoingAvatarStack(profiles: item.energy.socialPresenceProfiles, viewerUserID: viewModel.currentUserAuthId, diameter: 28)
            Text(item.energy.socialPresenceLabel ?? liveSocialPresenceText(item))
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(1)
        }
    }

    private func liveScorePill(_ score: Int) -> some View {
        Text("Energy \(score)")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(FGColor.accentGreen)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Capsule(style: .continuous).fill(Color.black.opacity(colorScheme == .dark ? 0.30 : 0.06)))
    }

    private func liveTokenTint(_ token: String) -> Color {
        if token.contains("LIVE") { return FGColor.dangerRed }
        if token.contains("Crowd") { return FGColor.accentGreen }
        if token.contains("Friend") { return FGColor.accentBlue }
        if token.contains("Chatting") { return FGColor.accentGreen }
        if token.contains("Starts") { return Color.orange }
        if token.contains("Need") { return FGColor.accentBlue }
        return colorScheme == .dark ? Color.white.opacity(0.82) : FGColor.secondaryText(colorScheme)
    }

    private func liveEnergyTokens(for item: LiveFeedItem) -> [String] {
        var tokens: [String] = []
        let status = resolveVenueEventMatchStatus(for: item)
        if status.isLive {
            tokens.append("LIVE NOW")
        } else if case .startingSoon = status {
            tokens.append("Starts Soon")
        } else if item.energy.startsSoon {
            tokens.append("Starts Soon")
        }
        if item.energy.goingCount > 0 && !status.isLive {
            tokens.append("Momentum")
        }
        if canShowPersonalLiveSections && item.energy.friendGoingCount > 0 {
            tokens.append("Friends Going")
        }
        return Array(tokens.reduce(into: [String]()) { unique, token in
            if !unique.contains(token) {
                unique.append(token)
            }
        }.prefix(4))
    }

    private func liveCrowdBuildingMoments(from rankedItems: [LiveFeedItem]) -> [LiveCrowdMomentum] {
        let qualified = rankedItems.compactMap { crowdMomentumCandidate(for: $0) }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.item.event.date < rhs.item.event.date
                }
                return lhs.score > rhs.score
            }
        let rendered = Array(qualified.prefix(6))
#if DEBUG
        if LiveRenderDiagnostics.enabled {
            print("[LiveCrowdDebug] candidates=\(rankedItems.count) qualified=\(qualified.count)")
            print("[LiveCrowdDebug] rendered=\(rendered.map(\.id).joined(separator: ","))")
        }
#endif
        return rendered
    }

    private func crowdMomentumCandidate(for item: LiveFeedItem) -> LiveCrowdMomentum? {
        // Crowd Building is venue activity, not sports LIVE.
        if resolveVenueEventMatchStatus(for: item).isLive { return nil }

        let packedCount = packedVibeCount(for: item.venueEventID)
        let homeCrowdFanCount = homeCrowdActivityCount(for: item.bar)
        let goingCount = item.energy.goingCount
        let chatCount = canShowPersonalLiveSections ? item.energy.commentCount : 0
        let friendGoingCount = canShowPersonalLiveSections ? item.energy.friendGoingCount : 0
        let vibeActivity = item.vibeCount

        let hasRealSignal = goingCount > 0
            || chatCount > 0
            || vibeActivity > 0
            || friendGoingCount > 0
            || homeCrowdFanCount > 0
        guard hasRealSignal else { return nil }

        let score = crowdMomentumScore(
            goingCount: goingCount,
            chatCount: chatCount,
            vibeActivity: vibeActivity,
            packedCount: packedCount,
            friendGoingCount: friendGoingCount,
            homeCrowdFanCount: homeCrowdFanCount,
            startsSoon: item.energy.startsSoon
        )
        guard score >= 10 else { return nil }

        let topVibe = crowdTopVibeLabel(for: item, packedCount: packedCount)
        return LiveCrowdMomentum(
            item: item,
            score: score,
            goingCount: goingCount,
            chatCount: chatCount,
            topVibeLabel: topVibe,
            homeCrowdFanCount: homeCrowdFanCount
        )
    }

    private func crowdMomentumScore(
        goingCount: Int,
        chatCount: Int,
        vibeActivity: Int,
        packedCount: Int,
        friendGoingCount: Int,
        homeCrowdFanCount: Int,
        startsSoon: Bool
    ) -> Int {
        (goingCount * 5)
            + (chatCount * 3)
            + (vibeActivity * 4)
            + (packedCount * 12)
            + (friendGoingCount * 15)
            + (min(homeCrowdFanCount, 24) * 2)
            + (startsSoon ? 8 : 0)
    }

    private func packedVibeCount(for venueEventID: UUID?) -> Int {
        guard let venueEventID else { return 0 }
        return fanUpdatesStore.venueEventVibeCounts[venueEventID]?["packed"] ?? 0
    }

    private func homeCrowdActivityCount(for bar: BarVenue) -> Int {
        guard viewModel.currentUserHomeCrowdVenueId == bar.id else { return 0 }
        return max(viewModel.currentUserHomeCrowdVenue?.fanCount ?? 0, 1)
    }

    private func crowdTopVibeLabel(for item: LiveFeedItem, packedCount: Int) -> String? {
        if packedCount > 0 {
            return packedCount == 1 ? "Packed Crowd" : "Packed Crowd · \(packedCount)"
        }
        if let top = item.topVibeText {
            if top.hasPrefix("Packed") {
                return top.replacingOccurrences(of: "Packed ·", with: "Packed Crowd ·")
            }
            return top
        }
        return nil
    }

    private func liveRankedItems(for day: Date) -> [LiveFeedItem] {
        let venues = viewModel.mapVisibleBars.isEmpty ? viewModel.bars : viewModel.mapVisibleBars
        let cal = Calendar.current
        var seen: Set<String> = []
        var items: [LiveFeedItem] = []

        for bar in venues {
            let dayEvents = viewModel.events.filter { event in
                cal.isDate(event.date, inSameDayAs: day) && bar.games.contains(event.title)
            }
            for event in dayEvents {
                let venueEventID = viewModel.cachedVenueEventID(for: bar, gameTitle: event.title)
                if let venueEventID,
                   let row = viewModel.venueEventRows.first(where: { $0.id == venueEventID }),
                   !VenueGameExpiration.isActiveOnDiscoverSurfaces(row: row) {
                    continue
                }
                let key = "\(bar.id.uuidString)-\(venueEventID?.uuidString ?? event.id.uuidString)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)

                let energy = viewModel.liveEnergy(for: bar, event: event, friendUserIDs: acceptedFriendUserIDs)
                let vibeCount = venueEventID.map {
                    fanUpdatesStore.venueEventVibeCounts[$0]?.values.reduce(0, +) ?? 0
                } ?? 0
                let topVibe = venueEventID.flatMap { topVibeText(for: $0) }
                let score = liveRankingScore(energy: energy, vibeCount: vibeCount)
                guard liveShouldInclude(energy: energy, vibeCount: vibeCount, score: score) else { continue }

                let item = LiveFeedItem(
                    id: key,
                    bar: bar,
                    event: event,
                    venueEventID: venueEventID,
                    energy: energy,
                    score: score,
                    vibeCount: vibeCount,
                    topVibeText: topVibe
                )
                logLiveRankedItem(item)
                items.append(item)
            }
        }

        return items.sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.event.date < rhs.event.date
            }
            return lhs.score > rhs.score
        }
    }

    private func liveShouldInclude(energy: FanGeoLiveEnergy, vibeCount: Int, score: Int) -> Bool {
        energy.isLiveNow
            || energy.startsSoon
            || (canShowPersonalLiveSections && energy.friendGoingCount > 0)
            || energy.goingCount > 0
            || (canShowPersonalLiveSections && energy.commentCount > 0)
            || vibeCount > 0
            || score >= 10
    }

    private func liveRankingScore(energy: FanGeoLiveEnergy, vibeCount: Int) -> Int {
        (energy.isLiveNow ? 10_000 : 0)
            + (energy.startsSoon ? 4_000 : 0)
            + (canShowPersonalLiveSections ? energy.friendGoingCount * 420 : 0)
            + (energy.goingCount * 42)
            + (canShowPersonalLiveSections ? energy.commentCount * 30 : 0)
            + (vibeCount * 24)
    }

    private func openLiveItem(_ item: LiveFeedItem) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            viewModel.selectedBar = item.bar
            viewModel.selectedEvent = item.event
            activeSheet = .venueDetails
        }
    }

    private func openVenueChatFromDetail(for bar: BarVenue) async {
        guard viewModel.isAuthenticatedForSocialFeatures else {
            viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
            return
        }
        guard viewModel.canUseFanSocialFeatures else {
            viewModel.logBusinessUserGateBlocked(action: "venueChat")
            fanFeatureGateAlertMessage = BusinessFanGateCopy.actionTapBlocked
            return
        }

        let chatBar = viewModel.barVenueForVenueChat(bar)
        let outcome = await chatViewModel.openBusinessVenueConversationFromVenueDetail(bar: chatBar)
        switch outcome {
        case .openedChat:
            activeSheet = nil
        case .needsVenuePicker:
            fanFeatureGateAlertMessage = "Choose a venue to continue."
        case .informational(let message):
            fanFeatureGateAlertMessage = message
        }
    }

    @ViewBuilder
    private func liveScreenSheetContent(for sheet: LiveScreenActiveSheet) -> some View {
        switch sheet {
        case .venueDetails:
            if canPresentVenueDetails {
                liveVenueDetailSheet()
            }
        case .venueRating:
            if let bar = viewModel.selectedBar, canPresentVenueRating {
                VenueUserRatingSheet(viewModel: viewModel, bar: bar)
            }
        case .watchSpots(let presentation):
            liveWatchSpotsSheet(items: presentation.items)
        case .matchDetail(let match):
            LiveMatchDetailSheet(
                match: match,
                viewModel: viewModel,
                onFindVenues: {
                    let related = liveMatchRelatedItems(
                        for: match,
                        in: liveRankedItems(for: liveCalendarToday)
                    )
                    liveFindVenuesTapped(match: match, relatedItems: related)
                }
            )
        case .proGamePrediction(let context):
            ProGamePredictionSheet(viewModel: viewModel, game: context.game)
        case .countryFilter:
            LiveLeagueCountryFilterSheet(
                countries: liveLeagueCountryOptions,
                suggestedNearYouCountry: liveNearYouSuggestedCountry,
                selection: Binding(
                    get: { liveLeagueCountryFilterSelection },
                    set: { updateLiveLeagueCountryFilterSelection($0) }
                )
            )
        case .fanUpdates(let event):
            if viewModel.isAuthenticatedForSocialFeatures {
                VenueEventCommentsSheet(
                    viewModel: viewModel,
                    venueEventID: event.id
                )
            }
        }
    }

    @ViewBuilder
    private func liveVenueDetailSheet() -> some View {
        if let selectedBar = viewModel.selectedBar {
            let claimStatus = viewModel.venueOwnershipClaimStatus(for: selectedBar)
            let selectedDayGames = viewModel.selectedDayEventsForMap(selectedBar)
            let selectedVenueEvent = selectedEventForVenue(gamesToday: selectedDayGames)
            let ratingCount = viewModel.reviewCountDisplay(for: selectedBar)
            let supportedSports = venueSupportedSports(from: selectedDayGames)
            let displaySport = venueSportLabel(sportsSupported: supportedSports)
            let liveEnergy = selectedVenueEvent.map {
                viewModel.liveEnergy(for: selectedBar, event: $0, friendUserIDs: acceptedFriendUserIDs)
            } ?? viewModel.strongestLiveEnergy(
                for: selectedBar,
                events: selectedDayGames,
                friendUserIDs: acceptedFriendUserIDs
            )
            let displayedLiveEnergy = liveEnergy.map(liveEnergyForCurrentAudience)
            let effectiveBusinessId = viewModel.effectiveBusinessIdForVenueChat(for: selectedBar)
            let isBusinessConfirmed = venueIsBusinessConfirmed(bar: selectedBar, claimStatus: claimStatus)
            let openVenueChatAction: (() async -> Void)? = {
                guard effectiveBusinessId != nil else { return nil }
                return { await openVenueChatFromDetail(for: selectedBar) }
            }()

            VenueDetailView(
                bar: selectedBar,
                selectedEvent: selectedVenueEvent,
                isFavorite: viewModel.canFavoriteVenues && viewModel.favoriteVenueIDs.contains(selectedBar.id),
                goingCount: viewModel.displayedGoingCount(for: selectedBar),
                liveEnergy: displayedLiveEnergy,
                livePresenceViewerUserID: viewModel.currentUserAuthId,
                iconForSport: viewModel.iconForSport,
                mergedRating: viewModel.mergedDisplayRating(for: selectedBar),
                ratingCount: ratingCount,
                displaySport: displaySport,
                sportsSupported: supportedSports,
                selectedTimeZone: viewModel.selectedTimeZone,
                hasGamesScheduledToday: !selectedDayGames.isEmpty,
                venueEventRows: viewModel.venueEventRows,
                venuePredictionSummaries: viewModel.venueEventPredictionSummaries,
                isBusinessConfirmed: isBusinessConfirmed,
                onDirections: { viewModel.openDirections(to: selectedBar) },
                onCall: { viewModel.callVenue(selectedBar) },
                onFavorite: {
                    if viewModel.canFavoriteVenues {
                        viewModel.toggleFavorite(selectedBar)
                    } else if viewModel.isGuestDiscoverMode {
                        viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
                    } else if viewModel.isAuthenticatedForSocialFeatures {
                        viewModel.logBusinessUserGateBlocked(action: "favoriteVenue")
                        fanFeatureGateAlertMessage = BusinessFanGateCopy.actionTapBlocked
                    }
                },
                onAddressTap: { viewModel.openDirections(to: selectedBar) },
                onRateVenue: {
                    if viewModel.canRateVenues {
                        activeSheet = .venueRating
                    } else if viewModel.isGuestDiscoverMode {
                        viewModel.discoverNavigateToAccountForUserAuth = true
                    } else if viewModel.isAuthenticatedForSocialFeatures {
                        viewModel.logBusinessUserGateBlocked(action: "rateVenue")
                        fanFeatureGateAlertMessage = BusinessFanGateCopy.actionTapBlocked
                    }
                },
                experience: viewModel.experience(for: selectedBar),
                coverPhotoURL: selectedBar.coverPhotoURL,
                menuPhotoURL: selectedBar.menuPhotoURL,
                onClaimThisBusiness: liveVenueClaimAction(for: selectedBar),
                showsBusinessOwnershipSection: viewModel.shouldShowVenueOwnershipClaimSection(for: selectedBar),
                businessClaimStatus: claimStatus,
                showsFanOnlyActionButtons: viewModel.isGuestDiscoverMode || viewModel.canUseFanSocialFeatures,
                onFanFeatureBlocked: { action in
                    viewModel.logBusinessUserGateBlocked(action: action)
                    fanFeatureGateAlertMessage = BusinessFanGateCopy.actionTapBlocked
                },
                locksScheduledGameDetailsForGuest: viewModel.isGuestDiscoverMode,
                onGuestGameLoginCTA: {
                    viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
                },
                onLoadVenuePredictionSummaries: { ids in
                    await viewModel.loadVenueEventPredictionSummaries(eventIDs: ids)
                },
                onRefreshVenuePredictionSummary: { id in
                    await viewModel.refreshVenueEventPredictionSummary(eventID: id)
                },
                onStartVenuePredictionRealtime: { id in
                    await viewModel.startVenueEventPredictionRealtime(for: id)
                },
                onStopVenuePredictionRealtime: { id in
                    await viewModel.stopVenueEventPredictionRealtime(for: id)
                },
                fanChatCommentCount: { id in
                    viewModel.fanUpdatesDisplayCommentCount(for: id)
                },
                venueEventVibeCounts: { id in
                    fanUpdatesStore.venueEventVibeCounts[id] ?? [:]
                },
                selectedVenueEventVibes: { id in
                    fanUpdatesStore.myVenueEventVibes[id] ?? []
                },
                onOpenFanChat: { id in
                    guard viewModel.isAuthenticatedForSocialFeatures else {
                        viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
                        return
                    }
                    FanUpdatesTapPerf.handleTap(eventId: id) {
                        activeSheet = .fanUpdates(FanUpdatesSheetEvent(id: id))
                    }
                },
                onToggleVenueEventVibe: { id, vibeType in
                    guard viewModel.isAuthenticatedForSocialFeatures else {
                        viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
                        return
                    }
                    guard viewModel.canUseFanSocialFeatures else {
                        viewModel.logBusinessUserGateBlocked(action: "toggleVibe")
                        fanFeatureGateAlertMessage = BusinessFanGateCopy.actionTapBlocked
                        return
                    }
                    await viewModel.toggleVibe(for: id, vibeType: vibeType)
                },
                onPrefetchVenueEventSocialData: { id in
                    viewModel.prefetchFanUpdatesCardSocialData(for: id)
                },
                showsHomeCrowdControls: viewModel.canUseFanSocialFeatures,
                isHomeCrowdVenue: viewModel.isHomeCrowdVenue(selectedBar.id),
                onToggleHomeCrowd: {
                    await viewModel.toggleHomeCrowd(for: selectedBar)
                },
                onOpenVenueChat: openVenueChatAction,
                effectiveBusinessId: effectiveBusinessId,
                showsUnclaimedBusinessCallout: selectedBar.isUnclaimedCommunityVenue && !isBusinessConfirmed,
                onBeginUnclaimedVenueClaim: {
                    viewModel.beginVenueClaimFromDiscover(bar: selectedBar)
                    activeSheet = nil
                },
                unclaimedSocialProofMetrics: (selectedBar.isUnclaimedCommunityVenue && !isBusinessConfirmed)
                    ? unclaimedVenueSocialProofMetrics(for: selectedBar, gamesToday: selectedDayGames)
                    : nil
            )
            .task {
                await viewModel.refreshApprovedVenueOwnershipState(for: selectedBar)
                await viewModel.ensureBusinessOwnerSessionFlagsIfPossible(context: "live_venue_detail_open")
                viewModel.logBusinessOwnerSessionFlags(context: "live_venue_detail_open")
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func unclaimedVenueSocialProofMetrics(
        for bar: BarVenue,
        gamesToday: [SportsEvent]
    ) -> UnclaimedVenueSocialProofMetrics {
        var extraEventIDs = Set<UUID>()
        for game in gamesToday {
            if let id = viewModel.peekVenueEventIDForRender(for: bar, gameTitle: game.title) {
                extraEventIDs.insert(id)
            }
        }
        let favoritedByFans: Int = {
            guard viewModel.currentUserHomeCrowdVenueId == bar.id else { return 0 }
            return max(0, viewModel.currentUserHomeCrowdVenue?.fanCount ?? 0)
        }()
        return UnclaimedVenueSocialProofBuilder.metrics(
            bar: bar,
            favoritedByFans: favoritedByFans,
            venueEventRows: viewModel.venueEventRows,
            extraEventIDs: Array(extraEventIDs),
            gamesTodayCount: gamesToday.count,
            interestCount: { viewModel.interestCountForVenueEvent($0) },
            commentCount: { viewModel.fanUpdatesDisplayCommentCount(for: $0) },
            vibeCounts: { fanUpdatesStore.venueEventVibeCounts[$0] ?? [:] }
        )
    }

    private func selectedEventForVenue(gamesToday: [SportsEvent]) -> SportsEvent? {
        guard let selectedEvent = viewModel.selectedEvent else { return nil }
        return gamesToday.first {
            $0.title == selectedEvent.title &&
            $0.sport == selectedEvent.sport &&
            Calendar.current.isDate($0.date, inSameDayAs: selectedEvent.date)
        }
    }

    private func venueIsBusinessConfirmed(bar: BarVenue, claimStatus: VenueOwnershipClaimStatus) -> Bool {
        let hasBusinessLink = viewModel.effectiveBusinessIdForVenueChat(for: bar) != nil || bar.ownerEmail != nil
        guard hasBusinessLink else { return false }
        switch claimStatus {
        case .approved, .alreadyClaimedByOtherBusiness:
            return true
        case .unclaimed, .pendingReview, .rejected:
            return false
        }
    }

    private func venueSupportedSports(from gamesToday: [SportsEvent]) -> [String] {
        Array(Set(gamesToday.compactMap { trimmedSportLabel($0.sport) })).sorted()
    }

    private func venueSportLabel(sportsSupported: [String]) -> String? {
        if sportsSupported.count > 1 { return "Multi-sport" }
        if let sport = sportsSupported.first { return sport }
        return nil
    }

    private func trimmedSportLabel(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func liveVenueClaimAction(for bar: BarVenue) -> ((BarVenue) async -> String?)? {
        guard viewModel.canSubmitVenueOwnershipClaim(for: bar) else { return nil }
        return { venue in
            await viewModel.submitVenueOwnershipClaimFromVenueDetail(bar: venue)
        }
    }

    private func topVibeText(for venueEventID: UUID) -> String? {
        let counts = fanUpdatesStore.venueEventVibeCounts[venueEventID] ?? [:]

        guard let top = counts.max(by: { $0.value < $1.value }),
              top.value > 0 else {
            return nil
        }

        switch top.key {
        case "audio_on":
            return "Audio confirmed · \(top.value)"
        case "packed":
            return "Packed · \(top.value)"
        case "seats_open":
            return "Seats open · \(top.value)"
        case "specials":
            return "Specials · \(top.value)"
        case "tv_visible":
            return "TVs visible · \(top.value)"
        default:
            return nil
        }
    }

    private func logFanUpdatesStoreMigrationDebug() {
#if DEBUG
        print("[FanUpdatesStoreMigrationDebug] LiveScreenVibeReadsStore=true")
#endif
    }

    private func logLiveFeedSnapshot(
        venuesAndPickupTodayCount: Int,
        friendsGoingCount: Int
    ) {
#if DEBUG
        if LiveRenderDiagnostics.enabled {
            print("[LiveTabDebug] venuesAndPickupTodayCount=\(venuesAndPickupTodayCount)")
            print("[LiveTabDebug] friendsGoingCount=\(friendsGoingCount)")
        }
#endif
    }

    private func visibleLiveSectionCount(
        matches: [LiveMatch],
        venuesAndPickupToday: [LiveVenuesPickupRow],
        friendsGoing: [LiveFeedItem],
        crowdBuilding: [LiveCrowdMomentum]
    ) -> Int {
        [
            !matches.isEmpty,
            !venuesAndPickupToday.isEmpty,
            !friendsGoing.isEmpty,
            !crowdBuilding.isEmpty
        ].filter { $0 }.count
    }

    private func logLivePolishSnapshot(visibleSectionCount: Int) {
#if DEBUG
        if LiveRenderDiagnostics.enabled {
            print("[LivePolishDebug] visibleSectionCount=\(visibleSectionCount)")
        }
#endif
    }

    private func logLiveBadgeDebug() {
#if DEBUG
        print("[LiveBadgeDebug] liveNowStyle=red")
#endif
    }

    private func logLiveFeedRefresh(reason: String) {
#if DEBUG
        if LiveRenderDiagnostics.enabled {
            print("[LiveTabDebug] liveFeedRefresh=\(reason)")
        }
#endif
    }

    private func logLiveAudienceDebug() {
#if DEBUG
        let hiddenSections = canShowPersonalLiveSections
            ? "none"
            : "Your Teams Live|Friends Going|Live Activity Sharing|favorite team momentum|friend avatar stacks|mutual friend presence|friend-based indicators"
        print("[LiveVisibilityDebug] isBusinessAccount=\(isBusinessLiveAudienceUser)")
        print("[LiveVisibilityDebug] hidingSocialLiveSections=\(!canShowPersonalLiveSections)")
        print("[LiveVisibilityDebug] renderingFanSections=\(canShowPersonalLiveSections)")
        print("[LiveAudienceDebug] isBusinessUser=\(isBusinessLiveAudienceUser)")
        print("[LiveAudienceDebug] hiddenPersonalLiveSections=\(hiddenSections)")
        print("[LiveAudienceDebug] regularUserPersonalLiveEnabled=\(canShowPersonalLiveSections)")
#endif
    }

    private func logLiveRankedItem(_ item: LiveFeedItem) {
#if DEBUG
        if LiveRenderDiagnostics.enabled {
            print("[LiveTabDebug] rankedVenueEvent=\(item.bar.name)|\(item.event.title)|score=\(item.score)")
        }
#endif
    }
}

private struct FavoriteTeamsLiveSection: View {
    let items: [LiveScreen.FavoriteTeamLiveItem]
    let favoriteTeams: [FavoriteTeam]
    let hasFavoriteTeams: Bool
    let onWatchNearby: (LiveScreen.FavoriteTeamLiveItem) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var languageCode: String { L10n.normalizedLanguageCode(appLanguageRaw) }

    private var headerAccent: Color {
        Color(red: 0.96, green: 0.78, blue: 0.18)
    }

    private var headerTeams: [FavoriteTeam] {
        Array(favoriteTeams.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                sectionHeaderIcon

                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t("Your Teams Live", languageCode: languageCode))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text(L10n.t("Favorite teams with live, nearby, and social momentum.", languageCode: languageCode))
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if items.isEmpty {
                Text(
                    hasFavoriteTeams
                        ? L10n.t("No favorite teams live right now", languageCode: languageCode)
                        : L10n.t("Favorite your teams to personalize Live.", languageCode: languageCode)
                )
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(sectionSurface(highlighted: hasFavoriteTeams))
            } else {
                VStack(spacing: 10) {
                    ForEach(items) { item in
                        FavoriteTeamLiveCard(item: item) {
                            onWatchNearby(item)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var sectionHeaderIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            headerTeams.isEmpty
                                ? headerAccent.opacity(colorScheme == .dark ? 0.22 : 0.14)
                                : Color.white.opacity(colorScheme == .dark ? 0.08 : 0.42)
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            Color.white.opacity(colorScheme == .dark ? 0.14 : 0.55),
                            lineWidth: 1
                        )
                }
                .frame(width: 40, height: 40)

            if headerTeams.isEmpty {
                Image(systemName: "star.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(headerAccent)
            } else {
                overlappingFavoriteTeamOrbs(teams: headerTeams)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            headerTeams.isEmpty
                ? "Your Teams Live"
                : "Your Teams Live, \(headerTeams.map(\.name).joined(separator: ", "))"
        )
    }

    private func overlappingFavoriteTeamOrbs(teams: [FavoriteTeam]) -> some View {
        let orbDiameter: CGFloat = 22
        return HStack(spacing: -(orbDiameter * 0.34)) {
            ForEach(teams) { team in
                SportsIdentityArtworkView(favoriteTeam: team, diameter: orbDiameter)
                    .overlay {
                        Circle()
                            .strokeBorder(
                                Color.white.opacity(colorScheme == .dark ? 0.55 : 0.92),
                                lineWidth: 1.5
                            )
                    }
                    .shadow(color: team.badgeColor.opacity(colorScheme == .dark ? 0.35 : 0.22), radius: 3, y: 1)
            }
        }
    }

    private func sectionSurface(highlighted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(colorScheme == .dark ? Color.white.opacity(0.075) : Color.white.opacity(0.78))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        highlighted
                            ? FGColor.accentGreen.opacity(colorScheme == .dark ? 0.24 : 0.16)
                            : FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 1 : 0.75),
                        lineWidth: 1
                    )
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.06), radius: 10, y: 5)
    }
}

struct LiveMatchDetailSheet: View {
    let match: LiveMatch
    /// When set, enables Save / Share / Predictions and Discover watch-spot helpers.
    var viewModel: MapViewModel? = nil
    var mapBounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)? = nil
    var showsDiscoverProGameActions: Bool = false
    var onSelectWatchSpot: ((BarVenue) -> Void)? = nil
    var onOpenInSchedule: (() -> Void)? = nil
    /// Live-tab Find Venues / Discover fallback (optional).
    var onFindVenues: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @State private var watchSpotsState: MapViewModel.DiscoverProGameWatchSpotsLoadState = .idle
    @State private var watchSpotsTask: Task<Void, Never>?

    private var languageCode: String { L10n.normalizedLanguageCode(appLanguageRaw) }

    private var sportType: LiveSportVisualType { match.liveSportVisualType }
    private var isFinalMatch: Bool { match.matchStatus == .fullTime }
    private var isLiveMatch: Bool { match.matchStatus.isHappeningNow }
    private var isUpcomingMatch: Bool { match.matchStatus == .scheduled }

    private var competitionLine: String {
        let candidates = [match.league, match.sourceLeagueName, match.leagueAlternate, match.eventName]
        for raw in candidates {
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    private var countryChipText: String {
        let country = match.leagueCountry?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !country.isEmpty else { return "" }
        return CountryFlagHelper.compactCountryChipText(for: country, source: "LiveDetail")
    }

    private var savedProGame: SavedProGame {
        if let viewModel {
            return SavedProGame.forPredictions(match: match, savedGames: viewModel.savedProGames)
        }
        return SavedProGame(match: match)
    }

    private var isSaved: Bool {
        viewModel?.isProGameSaved(match) ?? false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    heroCard
                    teamScoreCard
                    if let playedLocation {
                        venueSection(playedLocation)
                    }
                    matchMetaCard

                    if let tvDisplayText = match.tvDisplayText {
                        detailInfoPill(systemImage: "tv.fill", text: tvDisplayText)
                    }

                    if !match.goalTimelineEvents.isEmpty || match.resolvedGoalDisplaySummary != nil {
                        scoringSection
                    }

                    eventSection(
                        title: L10n.t("Cards", languageCode: languageCode),
                        systemImage: "rectangle.fill",
                        events: match.cardTimelineEvents
                    )
                    eventSection(
                        title: L10n.t("Substitutions", languageCode: languageCode),
                        systemImage: "arrow.left.arrow.right",
                        events: match.substitutionTimelineEvents
                    )

                    if viewModel != nil || onFindVenues != nil || showsDiscoverProGameActions {
                        actionsSection
                    }

                    if showsDiscoverProGameActions {
                        discoverWatchSpotsSection
                        discoverOpenInScheduleButton
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(L10n.t("Match Details", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Done", languageCode: languageCode)) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let viewModel {
                        ProGameShareActionButton(game: savedProGame, mapViewModel: viewModel) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(FGColor.accentBlue)
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task(id: discoverWatchSpotsTaskID) {
            await loadDiscoverWatchSpotsIfNeeded()
        }
        .onDisappear {
            watchSpotsTask?.cancel()
            watchSpotsTask = nil
        }
    }

    private var discoverWatchSpotsTaskID: String {
        guard showsDiscoverProGameActions else { return "off" }
        let boundsKey: String = {
            guard let mapBounds else { return "nobounds" }
            return String(
                format: "%.4f:%.4f:%.4f:%.4f",
                mapBounds.minLat,
                mapBounds.maxLat,
                mapBounds.minLon,
                mapBounds.maxLon
            )
        }()
        return "\(SavedProGame.stableKey(for: match))|\(boundsKey)"
    }

    @ViewBuilder
    private var discoverWatchSpotsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top venues for this game")
                .font(FGTypography.cardTitle)
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .accessibilityAddTraits(.isHeader)

            Text("Based on live fan activity")
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))

            switch watchSpotsState {
            case .idle, .loading:
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.t("discover_pro_game_watch_spots_loading", languageCode: languageCode))
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L10n.t("discover_pro_game_watch_spots_loading", languageCode: languageCode))

            case .unavailable:
                discoverWatchSpotsMessageCard(
                    title: L10n.t("discover_pro_game_watch_spots_unavailable_title", languageCode: languageCode),
                    supporting: L10n.t("discover_pro_game_watch_spots_unavailable_supporting", languageCode: languageCode)
                )

            case .loaded(let spots) where spots.isEmpty:
                discoverWatchSpotsMessageCard(
                    title: L10n.t("discover_pro_game_watch_spots_empty_title", languageCode: languageCode),
                    supporting: L10n.t("discover_pro_game_watch_spots_empty_supporting", languageCode: languageCode)
                )

            case .loaded(let spots):
                VStack(spacing: 10) {
                    ForEach(spots) { spot in
                        Button {
                            onSelectWatchSpot?(spot.bar)
                        } label: {
                            discoverWatchSpotRow(spot)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func discoverWatchSpotsMessageCard(title: String, supporting: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(FGTypography.body.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Text(supporting)
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.72))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(supporting)")
    }

    private func discoverWatchSpotRow(_ spot: MapViewModel.DiscoverProGameWatchSpot) -> some View {
        let bar = spot.bar
        let location = discoverWatchSpotLocationText(for: bar)
        let distanceText = spot.distanceFromRegionCenterMiles.map { miles -> String in
            if miles < 10 {
                return String(format: "%.1f mi", miles)
            }
            return String(format: "%.0f mi", miles)
        }

        return HStack(alignment: .center, spacing: 12) {
            discoverWatchSpotThumbnail(bar)

            VStack(alignment: .leading, spacing: 4) {
                Text(bar.name)
                    .font(FGTypography.cardTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if !location.isEmpty {
                    Text(location)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    if !spot.energyCaption.isEmpty {
                        Text(spot.energyCaption)
                            .font(FGTypography.metadata.weight(.bold))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(1)
                    } else if spot.isLiveNow {
                        Text("LIVE")
                            .font(FGTypography.metadata.weight(.bold))
                            .foregroundStyle(FGColor.dangerRed)
                            .lineLimit(1)
                    }

                    Text(L10n.t("discover_pro_game_watch_spot_showing_status", languageCode: languageCode))
                        .font(FGTypography.metadata.weight(.bold))
                        .foregroundStyle(FGColor.intentWatch)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill(FGColor.intentWatch.opacity(colorScheme == .dark ? 0.18 : 0.12))
                        )

                    if spot.goingCount > 0 {
                        Text(spot.goingCount == 1 ? "1 Going" : "\(spot.goingCount) Going")
                            .font(FGTypography.metadata.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                    }

                    if let distanceText {
                        Text(distanceText)
                            .font(FGTypography.metadata.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                }
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .accessibilityHidden(true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.72))
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [
                bar.name,
                location,
                spot.energyCaption.isEmpty ? nil : spot.energyCaption,
                spot.goingCount > 0 ? "\(spot.goingCount) Going" : nil,
                L10n.t("discover_pro_game_watch_spot_showing_status", languageCode: languageCode),
                distanceText
            ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
        )
        .accessibilityHint(L10n.t("discover_pro_game_watch_spot_a11y_hint", languageCode: languageCode))
    }

    @ViewBuilder
    private func discoverWatchSpotThumbnail(_ bar: BarVenue) -> some View {
        let urlString = ImageDisplayURL.forList(
            thumbnail: bar.coverPhotoThumbnailURL,
            full: bar.coverPhotoURL
        )
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(FGColor.intentWatch.opacity(colorScheme == .dark ? 0.18 : 0.10))
            if let urlString, let url = URL(string: urlString) {
                DiscoverCachedRemoteImage(url: url, contentMode: .fill) {
                    Image(systemName: "building.2.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(FGColor.intentWatch)
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Image(systemName: "building.2.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(FGColor.intentWatch)
            }
        }
        .frame(width: 48, height: 48)
        .accessibilityHidden(true)
    }

    private func discoverWatchSpotLocationText(for bar: BarVenue) -> String {
        let address = bar.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return "" }
        let parts = address.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        if parts.count >= 2 {
            return parts.suffix(2).joined(separator: ", ")
        }
        return parts.first.map { String($0) } ?? address
    }

    private var discoverOpenInScheduleButton: some View {
        FGPrimaryButton(
            title: L10n.t("discover_pro_game_open_in_schedule", languageCode: languageCode),
            systemImage: "calendar"
        ) {
            onOpenInSchedule?()
            dismiss()
        }
        .padding(.top, 4)
        .accessibilityHint(L10n.t("discover_pro_game_open_in_schedule_a11y_hint", languageCode: languageCode))
    }

    private func loadDiscoverWatchSpotsIfNeeded() async {
        guard showsDiscoverProGameActions, let viewModel else {
            watchSpotsState = .idle
            return
        }
        watchSpotsTask?.cancel()
        watchSpotsState = .loading
        let task = Task { @MainActor in
            let result = await viewModel.loadDiscoverWatchSpots(
                for: match,
                mapBounds: mapBounds,
                limit: 5
            )
            guard !Task.isCancelled else { return }
            watchSpotsState = result
        }
        watchSpotsTask = task
        await task.value
    }

    // MARK: - Hero / score / meta

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !competitionLine.isEmpty {
                Text(competitionLine)
                    .font(FGTypography.cardTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)
                    .minimumScaleFactor(0.9)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 7) {
                if !countryChipText.isEmpty {
                    detailChip(text: countryChipText, tint: FGColor.secondaryText(colorScheme))
                }
                detailChip(text: sportType.displayLabel, tint: sportType.catalogAccent)
                detailStatusChip
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(detailCardBackground(cornerRadius: 22))
    }

    private var teamScoreCard: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                detailTeamColumn(
                    name: match.awayTeam,
                    badgeURL: match.awayTeamBadgeURL,
                    alignment: .leading
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                detailCenterScoreBlock
                    .layoutPriority(2)

                detailTeamColumn(
                    name: match.homeTeam,
                    badgeURL: match.homeTeamBadgeURL,
                    alignment: .trailing
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(detailCardBackground(cornerRadius: 22))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(detailMatchupAccessibilityLabel)
    }

    private var detailCenterScoreBlock: some View {
        VStack(spacing: 4) {
            if match.scoresAreAvailable, (isLiveMatch || isFinalMatch) {
                Text("\(match.scoreAway) – \(match.scoreHome)")
                    .font(.system(size: 34, weight: .black, design: .rounded).monospacedDigit())
                    .foregroundStyle(isLiveMatch ? FGColor.dangerRed : FGColor.primaryText(colorScheme))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            } else {
                Text(detailKickoffTimeText)
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
                    .lineLimit(2)
                Text(detailDateText)
                    .font(FGTypography.metadata.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(minWidth: 88)
    }

    private func detailTeamColumn(
        name: String,
        badgeURL: String?,
        alignment: HorizontalAlignment
    ) -> some View {
        let identity = ProGameTeamScoreIdentity.resolve(teamName: name, badgeURL: badgeURL, source: "LiveDetail")
        return VStack(alignment: alignment, spacing: 8) {
            detailTeamEmblem(identity)
            Text(identity.displayName)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
                .lineLimit(3)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
        }
    }

    @ViewBuilder
    private func detailTeamEmblem(_ identity: ProGameTeamScoreIdentity) -> some View {
        switch identity.leading {
        case let .flag(flag):
            Text(flag)
                .font(.system(size: 28))
                .accessibilityHidden(true)
        case let .logoURL(url):
            DiscoverCachedRemoteImage(url: url, contentMode: .fit) {
                detailInitialsBadge(identity.displayName)
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
        case .none:
            detailInitialsBadge(identity.displayName)
        }
    }

    private func detailInitialsBadge(_ name: String) -> some View {
        let initials = name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined()
        return Text(initials.isEmpty ? String(name.prefix(2)) : initials)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(FGColor.secondaryText(colorScheme))
            .frame(width: 36, height: 36)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(FGColor.divider(colorScheme).opacity(0.35))
            )
            .accessibilityHidden(true)
    }

    // MARK: - Where It’s Played

    private var competitionCountryDisplay: String {
        let raw = match.leagueCountry?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return "" }
        let display = CountryFlagHelper.displayName(for: raw, languageCode: languageCode)
        return display.isEmpty ? raw : display
    }

    private var playedLocation: LiveMatchPlayedLocationPresentation.Resolved? {
        LiveMatchPlayedLocationPresentation.resolve(
            venueName: match.venueName,
            venueCity: match.venueCity,
            leagueCountry: match.leagueCountry,
            coordinate: match.venueCoordinate,
            localizedCountryName: competitionCountryDisplay
        )
    }

    private var specificMetaCity: String? {
        let parsed = LiveMatchPlayedLocationPresentation.parseCityBlob(
            LiveMatchPlayedLocationPresentation.cleaned(match.venueCity)
        )
        return LiveMatchPlayedLocationPresentation.meaningfulCity(parsed.city)
    }

    private var specificMetaRegion: String? {
        let parsed = LiveMatchPlayedLocationPresentation.parseCityBlob(
            LiveMatchPlayedLocationPresentation.cleaned(match.venueCity)
        )
        return LiveMatchPlayedLocationPresentation.meaningfulRegion(parsed.region)
    }

    private var specificMetaStadium: String? {
        LiveMatchPlayedLocationPresentation.meaningfulVenueName(
            LiveMatchPlayedLocationPresentation.cleaned(match.venueName)
        )
    }

    @ViewBuilder
    private func venueSection(_ location: LiveMatchPlayedLocationPresentation.Resolved) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("live_match_detail_where_played", languageCode: languageCode))
                .font(FGTypography.caption.weight(.heavy))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .textCase(.uppercase)
                .tracking(0.6)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 0) {
                venueInfoRow(location)

                if let coordinate = location.coordinate {
                    venueMapPreview(location: location, coordinate: coordinate)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(detailCardBackground(cornerRadius: 20))
        }
    }

    private func venueInfoRow(_ location: LiveMatchPlayedLocationPresentation.Resolved) -> some View {
        let tappable = location.canOpenMaps
        return Button {
            guard tappable else { return }
            openVenueInAppleMaps(location)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    if let title = location.primaryTitle, !title.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("🏟️")
                                .font(.body)
                                .accessibilityHidden(true)
                            Text(title)
                                .font(FGTypography.cardTitle)
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                                .multilineTextAlignment(.leading)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let locality = location.localityLine, !locality.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("📍")
                                .font(.body)
                                .accessibilityHidden(true)
                            Text(locality)
                                .font(FGTypography.body.weight(.medium))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .multilineTextAlignment(.leading)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if tappable {
                        Text(L10n.t("live_match_detail_open_in_maps", languageCode: languageCode))
                            .font(FGTypography.metadata.weight(.bold))
                            .foregroundStyle(FGColor.accentBlue)
                            .padding(.top, 2)
                    }
                }

                Spacer(minLength: 0)

                if tappable {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(FGColor.accentBlue)
                        .accessibilityHidden(true)
                }
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!tappable)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(venueAccessibilityLabel(location))
        .accessibilityHint(
            tappable
                ? L10n.t("live_match_detail_open_in_maps", languageCode: languageCode)
                : ""
        )
        .accessibilityAddTraits(tappable ? .isButton : [])
    }

    private func venueAccessibilityLabel(_ location: LiveMatchPlayedLocationPresentation.Resolved) -> String {
        [location.primaryTitle, location.localityLine]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
    }

    private func venueMapPreview(
        location: LiveMatchPlayedLocationPresentation.Resolved,
        coordinate: CLLocationCoordinate2D
    ) -> some View {
        let region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
        )
        return Button {
            openVenueInAppleMaps(location)
        } label: {
            Map(initialPosition: .region(region)) {
                Marker(location.mapTitle, coordinate: coordinate)
            }
            .mapStyle(.standard(elevation: .flat))
            .disabled(true)
            .frame(maxWidth: .infinity)
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme).opacity(0.8), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(venueAccessibilityLabel(location))
        .accessibilityHint(L10n.t("live_match_detail_open_in_maps", languageCode: languageCode))
    }

    private func openVenueInAppleMaps(_ location: LiveMatchPlayedLocationPresentation.Resolved) {
        if let coordinate = location.coordinate {
            let item = MKMapItem(
                location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
                address: nil
            )
            item.name = location.mapTitle
            item.openInMaps()
            return
        }

        let query = location.mapsSearchQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else { return }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { return }
        UIApplication.shared.open(url)
    }

    @ViewBuilder
    private var matchMetaCard: some View {
        let rows = detailMetaRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.label)
                            .font(FGTypography.metadata.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .frame(minWidth: 120, alignment: .leading)
                        Text(row.value)
                            .font(FGTypography.body.weight(.semibold))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10)
                    if index < rows.count - 1 {
                        Divider().opacity(0.55)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(detailCardBackground(cornerRadius: 20))
        }
    }

    private var detailMetaRows: [(label: String, value: String)] {
        var rows: [(String, String)] = []
        rows.append(("📅 \(L10n.t("Date", languageCode: languageCode))", detailDateText))
        rows.append(("🕒 \(L10n.t("live_match_detail_time", languageCode: languageCode))", detailKickoffTimeText))
        if !competitionLine.isEmpty {
            rows.append(("🏆 \(L10n.t("live_match_detail_competition", languageCode: languageCode))", competitionLine))
        }
        if let stadium = specificMetaStadium {
            rows.append(("🏟 \(L10n.t("Venue", languageCode: languageCode))", stadium))
        }
        if let city = specificMetaCity {
            rows.append(("📍 \(L10n.t("live_match_detail_city", languageCode: languageCode))", city))
        }
        if let region = specificMetaRegion {
            rows.append(("🗺 \(L10n.t("State", languageCode: languageCode))", region))
        }
        // Competition country belongs in metadata — never used alone as match location.
        if !competitionCountryDisplay.isEmpty {
            rows.append(("🌍 \(L10n.t("Country", languageCode: languageCode))", competitionCountryDisplay))
        }
        rows.append(("📡 \(L10n.t("live_match_detail_status", languageCode: languageCode))", statusText))
        if isLiveMatch, let minute = match.minute {
            rows.append(("⏱ \(L10n.t("live_match_detail_minute", languageCode: languageCode))", "\(minute)’"))
        } else if let clock = match.liveClockText?.trimmingCharacters(in: .whitespacesAndNewlines), !clock.isEmpty, isLiveMatch {
            rows.append(("⏱ \(L10n.t("live_match_detail_minute", languageCode: languageCode))", clock))
        }
        return rows
    }

    @ViewBuilder
    private var scoringSection: some View {
        if !match.goalTimelineEvents.isEmpty {
            eventSection(
                title: L10n.t("Goals", languageCode: languageCode),
                systemImage: "soccerball",
                events: match.goalTimelineEvents
            )
        } else if let summary = match.resolvedGoalDisplaySummary, summary.hasContent {
            VStack(alignment: .leading, spacing: 10) {
                Label(L10n.t("Goals", languageCode: languageCode), systemImage: "soccerball")
                    .font(FGTypography.cardTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                ProGameScoringTimelineView(
                    summary: summary,
                    homeTeam: match.homeTeam,
                    awayTeam: match.awayTeam,
                    gameId: SavedProGame.stableKey(for: match),
                    headingColor: FGColor.secondaryText(colorScheme),
                    lineColor: FGColor.primaryText(colorScheme),
                    flagSource: "LiveDetail"
                )
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(detailCardBackground(cornerRadius: 16))
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        let showSave = viewModel != nil
        let showFind = onFindVenues != nil
        if showSave || showFind {
            HStack(spacing: 10) {
                if let viewModel {
                    detailActionButton(
                        title: isSaved
                            ? L10n.t("live_match_detail_unsave", languageCode: languageCode)
                            : L10n.t("Save", languageCode: languageCode),
                        systemImage: isSaved ? "heart.fill" : "heart",
                        tint: isSaved ? Color.red.opacity(0.95) : FGColor.accentBlue
                    ) {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            viewModel.toggleSavedProGame(match)
                        }
                    }
                }

                if let onFindVenues {
                    detailActionButton(
                        title: L10n.t("live_match_detail_find_venues", languageCode: languageCode),
                        systemImage: "map.fill",
                        tint: sportType.catalogAccent,
                        action: onFindVenues
                    )
                }
            }
        }
    }

    private func detailActionButton(
        title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.bold))
                Text(title)
                    .font(FGTypography.metadata.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(colorScheme == .dark ? 0.18 : 0.10))
            )
        }
        .buttonStyle(.plain)
    }

    private var detailStatusChip: some View {
        let tint: Color = {
            if isLiveMatch { return FGColor.dangerRed }
            if isFinalMatch { return FGColor.mutedText(colorScheme) }
            return sportType.catalogAccent
        }()
        return detailChip(text: statusText, tint: tint)
    }

    private func detailChip(text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule(style: .continuous).fill(tint.opacity(colorScheme == .dark ? 0.18 : 0.11)))
            .lineLimit(1)
    }

    private func detailCardBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.92))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 1 : 0.7), lineWidth: 1)
            }
    }

    private var statusText: String {
        switch match.matchStatus {
        case .live:
            if let minute = match.minute {
                return "\(L10n.t("LIVE", languageCode: languageCode)) \(minute)’"
            }
            return L10n.t("LIVE", languageCode: languageCode)
        case .halfTime:
            return L10n.t("Halftime", languageCode: languageCode)
        case .fullTime:
            return L10n.t("FINAL", languageCode: languageCode)
        case .scheduled:
            return L10n.t("Scheduled", languageCode: languageCode)
        }
    }

    private var detailDateText: String {
        match.startTime.formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted)
                .locale(Locale(identifier: languageCode))
        )
    }

    private var detailKickoffTimeText: String {
        match.startTime.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened)
                .locale(Locale(identifier: languageCode))
        )
    }

    private var detailMatchupAccessibilityLabel: String {
        if match.scoresAreAvailable {
            return "\(match.awayTeam) \(match.scoreAway) \(match.scoreHome) \(match.homeTeam)"
        }
        return "\(match.awayTeam) \(match.homeTeam) \(detailKickoffTimeText)"
    }

    @ViewBuilder
    private func eventSection(title: String, systemImage: String, events: [LiveTimelineEvent]) -> some View {
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: systemImage)
                    .font(FGTypography.cardTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))

                VStack(spacing: 8) {
                    ForEach(events) { event in
                        eventRow(event)
                    }
                }
            }
        }
    }

    private func eventRow(_ event: LiveTimelineEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(event.minuteText ?? "-")
                .font(FGTypography.metadata.weight(.bold).monospacedDigit())
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .frame(width: 42, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(eventTitle(event))
                    .font(FGTypography.body.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)

                Text(eventSubtitle(event))
                    .font(FGTypography.metadata)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(detailCardBackground(cornerRadius: 16))
    }

    private func eventTitle(_ event: LiveTimelineEvent) -> String {
        if event.isSubstitution, let player = event.playerDisplayName, let assist = event.assistDisplayName {
            return "\(player) -> \(assist)"
        }
        return event.playerDisplayName ?? event.strTeam ?? event.typeText
    }

    private func eventSubtitle(_ event: LiveTimelineEvent) -> String {
        var parts: [String] = [event.typeText]
        if event.isGoal, let assist = event.assistDisplayName {
            parts.append("Assist: \(assist)")
        }
        if let team = event.strTeam?.trimmingCharacters(in: .whitespacesAndNewlines), !team.isEmpty {
            parts.append(team)
        }
        return parts.joined(separator: " · ")
    }

    private func detailInfoPill(systemImage: String, text: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(FGTypography.metadata.weight(.semibold))
            .foregroundStyle(FGColor.secondaryText(colorScheme))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(detailCardBackground(cornerRadius: 16))
    }
}


private struct LiveLeagueCountryFilterSheet: View {
    let countries: [String]
    let suggestedNearYouCountry: String?
    @Binding var selection: LiveLeagueCountryFilterSelection

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var languageCode: String { L10n.normalizedLanguageCode(appLanguageRaw) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.t("Live Countries", languageCode: languageCode))
                            .font(FGTypography.sectionTitle)
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                        Text(L10n.t("Choose which league countries appear in your Live feed.", languageCode: languageCode))
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                    .padding(.vertical, 4)
                }

                if let nearYou = suggestedNearYouCountry {
                    Section {
                        let nearYouDisplay = LiveLeagueCountryFilterPresentation.localizedCountryDisplayName(
                            nearYou,
                            languageCode: languageCode
                        )
                        let isSelected = selection.containsCountryInSelectionOrGroup(nearYou)
                        countryRow(
                            title: nearYouDisplay,
                            subtitle: L10n.t("near_you", languageCode: languageCode),
                            flag: CountryFlagHelper.flag(for: nearYou),
                            isSelected: isSelected,
                            accessibilityLabel: String(
                                format: L10n.t("near_you_country_a11y_format", languageCode: languageCode),
                                locale: Locale(identifier: languageCode),
                                nearYouDisplay
                            ),
                            accessibilityHint: countryToggleHint(isSelected: isSelected)
                        ) {
                            applySelection(LiveLeagueCountryFilterPresentation.togglingCountry(nearYou, in: selection))
                        }
                    }
                }

                Section("Quick Actions") {
                    quickAction(
                        title: L10n.t("country_filter_select_all", languageCode: languageCode),
                        accessibilityHint: L10n.t("country_filter_select_all_a11y_hint", languageCode: languageCode)
                    ) {
                        applySelection(
                            LiveLeagueCountryFilterSelection(
                                groups: [],
                                countries: Set(countries.compactMap { LiveLeagueCountryResolver.normalizedCountry($0) })
                            )
                        )
                    }
                    quickAction(
                        title: L10n.t("country_filter_clear", languageCode: languageCode),
                        accessibilityHint: L10n.t("country_filter_clear_a11y_hint", languageCode: languageCode)
                    ) {
                        applySelection(.empty)
                    }
                    presetRow(
                        title: L10n.t("live_region_north_america", languageCode: languageCode),
                        groupID: .northAmerica,
                        accessibilityHint: L10n.t("country_filter_preset_a11y_hint", languageCode: languageCode)
                    )
                    presetRow(
                        title: L10n.t("country_filter_top_european", languageCode: languageCode),
                        groupID: .topEurope,
                        accessibilityHint: L10n.t("country_filter_preset_a11y_hint", languageCode: languageCode)
                    )
                }

                Section {
                    ForEach(countries, id: \.self) { country in
                        let isSelected = selection.containsCountryInSelectionOrGroup(country)
                        let displayName = LiveLeagueCountryFilterPresentation.localizedCountryDisplayName(
                            country,
                            languageCode: languageCode
                        )
                        countryRow(
                            title: displayName,
                            subtitle: nil,
                            flag: nil,
                            isSelected: isSelected,
                            accessibilityLabel: displayName,
                            accessibilityHint: countryToggleHint(isSelected: isSelected)
                        ) {
                            applySelection(LiveLeagueCountryFilterPresentation.togglingCountry(country, in: selection))
                        }
                    }
                } header: {
                    Text(L10n.t("Countries", languageCode: languageCode))
                }
            }
            .navigationTitle(L10n.t("Live Countries", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("Close", languageCode: languageCode)) {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func applySelection(_ next: LiveLeagueCountryFilterSelection) {
        selection = next
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

    private func presetRow(
        title: String,
        groupID: LiveLeagueCountryFilterGroupID,
        accessibilityHint: String
    ) -> some View {
        let state = LiveLeagueCountryFilterPresentation.presetSelectionState(groupID, in: selection)
        return Button {
            applySelection(LiveLeagueCountryFilterPresentation.togglingGroup(groupID, in: selection))
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

private struct FavoriteTeamLiveCard: View {
    let item: LiveScreen.FavoriteTeamLiveItem
    let onWatchNearby: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var languageCode: String { L10n.normalizedLanguageCode(appLanguageRaw) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                LiveCanonicalStatusPill(status: item.canonicalStatus, languageCode: languageCode)
                Text(item.team.name)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(item.team.badgeColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
                SportsIdentityArtworkView(favoriteTeam: item.team, diameter: 28)
                    .accessibilityHidden(true)
            }

            if let away = item.awayTeam, let home = item.homeTeam {
                LiveCompactMatchupRow(
                    awayTeam: away,
                    homeTeam: home,
                    awayScore: item.awayScore,
                    homeScore: item.homeScore,
                    scoresAvailable: item.scoresAvailable,
                    awayBadgeURL: item.awayBadgeURL,
                    homeBadgeURL: item.homeBadgeURL
                )
            } else {
                Text(item.title)
                    .font(FGTypography.cardTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)
            }

            Text(item.leagueSportText)
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .lineLimit(1)

            if item.isRecentFinalFallback {
                Text(L10n.t("Recent final", languageCode: languageCode))
                    .font(FGTypography.metadata.weight(.semibold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            }

            if item.nearbyVenueCount > 0 {
                Text(
                    item.nearbyVenueCount == 1
                        ? L10n.t("1 venue showing", languageCode: languageCode)
                        : String(format: L10n.t("%lld venues showing", languageCode: languageCode), item.nearbyVenueCount)
                )
                .font(FGTypography.metadata.weight(.semibold))
                .foregroundStyle(item.team.badgeColor)
            }

            if !item.socialTokens.isEmpty {
                FGWrappingLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(item.socialTokens.filter { !$0.contains("venue showing") }, id: \.self) { token in
                        socialToken(token)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: onWatchNearby) {
                HStack {
                    Spacer(minLength: 0)
                    Text(L10n.t("Watch Nearby", languageCode: languageCode))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule(style: .continuous).fill(FGColor.accentGreen))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("Watch Nearby", languageCode: languageCode))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardSurface)
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(item.team.badgeColor.opacity(colorScheme == .dark ? 0.18 : 0.11))
                .frame(width: 86, height: 86)
                .blur(radius: 28)
                .offset(x: 24, y: -34)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func socialToken(_ token: String) -> some View {
        Text(token)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(tokenTint(token))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(tokenTint(token).opacity(colorScheme == .dark ? 0.16 : 0.10)))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(tokenTint(token).opacity(0.24), lineWidth: 1)
            }
    }

    private func tokenTint(_ token: String) -> Color {
        if token.contains("friend") { return FGColor.accentBlue }
        if token.contains("venue") { return item.team.badgeColor }
        if token.contains("crowd") { return FGColor.accentGreen }
        return colorScheme == .dark ? Color.white.opacity(0.84) : FGColor.secondaryText(colorScheme)
    }

    private var cardSurface: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [Color.white.opacity(0.105), item.team.badgeColor.opacity(0.10)]
                        : [Color.white.opacity(0.86), item.team.badgeColor.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(item.team.badgeColor.opacity(colorScheme == .dark ? 0.32 : 0.20), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.07), radius: 16, y: 8)
    }
}


private struct LiveSummaryChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeInOut(duration: 0.14), value: configuration.isPressed)
    }
}
