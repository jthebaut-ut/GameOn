import SwiftUI
import CoreLocation
import MapKit

/// Compact Discover activity summary. Counts are derived from already-loaded in-memory data only.
enum FanGeoDiscoverActivityPanelPreferences {
    private static let introShownKeyPrefix = "discoverActivityPanelIntroShown"
    private static let guestIntroShownKey = "discoverActivityPanelIntroShown.guest"
    private static let stateKeyPrefix = "discoverActivityPanelState"
    private static let guestStateKey = "discoverActivityPanelState.guest"

    /// Guest → `discoverActivityPanelIntroShown.guest`; signed-in → `…IntroShown.<uuid>`.
    private static func introKey(for userId: UUID?) -> String {
        guard let userId else { return guestIntroShownKey }
        return "\(introShownKeyPrefix).\(userId.uuidString.lowercased())"
    }

    private static func stateKey(for userId: UUID?) -> String {
        guard let userId else { return guestStateKey }
        return "\(stateKeyPrefix).\(userId.uuidString.lowercased())"
    }

    static func hasShownIntro(for userId: UUID?) -> Bool {
        UserDefaults.standard.bool(forKey: introKey(for: userId))
    }

    /// Call only after the user collapses, hides, or otherwise explicitly interacts during intro.
    static func markIntroShown(for userId: UUID?) {
        UserDefaults.standard.set(true, forKey: introKey(for: userId))
    }

    /// Restores only `hidden` or `compact`. Expanded always restores as compact.
    static func restoredState(for userId: UUID?) -> DiscoverActivityPanelState {
        let raw = UserDefaults.standard.string(forKey: stateKey(for: userId)) ?? ""
        switch raw {
        case DiscoverActivityPanelState.hidden.persistenceRawValue:
            return .hidden
        default:
            return .compact
        }
    }

    /// Persists only durable preferences (hidden / compact). Expanded is stored as compact.
    static func persistState(_ state: DiscoverActivityPanelState, for userId: UUID?) {
        let durable: DiscoverActivityPanelState = (state == .expanded) ? .compact : state
        UserDefaults.standard.set(durable.persistenceRawValue, forKey: stateKey(for: userId))
    }
}

enum DiscoverActivityPanelState: Equatable {
    case hidden
    case compact
    case expanded

    var persistenceRawValue: String {
        switch self {
        case .hidden: return "hidden"
        case .compact, .expanded: return "compact"
        }
    }
}

/// Back-compat alias used by DiscoverScreen during the rename.
typealias DiscoverActivityPanelExpansion = DiscoverActivityPanelState

// MARK: - Metric item (precomputed, Equatable leaf props)

/// Short metric cards only. Detail/timely/favorite insights use `DiscoverPersonalizedInsight`.
///
/// **Fans nearby:** real integer from ``FansNearbyService`` / `get_nearby_fan_count` only.
/// Do not derive from Suggested Fans, Going, venue attendance, client profile enumeration,
/// precise locations, or map pins. Guest teaser never calls the aggregate.
struct DiscoverActivityPanelItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case fansNearby
        case venuePlansToday
        case pickupPlansToday
        case suggestedFans
        /// Guest-only compact metric (map pickup starts soon).
        case pickupSoon
        /// Guest-only Create Account teaser.
        case favoriteTeam
    }

    let id: String
    let kind: Kind
    let valueText: String
    let labelText: String
    /// Expanded supporting line when present (guest teasers / signed-in fans-nearby placeholder).
    let supportingText: String?
    let systemImage: String
    let accessibilityLabel: String
    /// Guest Create Account / signed-in typed destinations. Never invent new auth flows.
    let isTappable: Bool
    let valueUsesMonospacedDigits: Bool
}

/// Signed-in compact Today dashboard snapshot (built outside SwiftUI `body`).
struct DiscoverTodayDashboardPresentation: Equatable {
    let fansNearby: DiscoverActivityPanelItem
    let venuePlansToday: DiscoverActivityPanelItem
    let pickupPlansToday: DiscoverActivityPanelItem
    let suggestedFans: DiscoverActivityPanelItem
    let favoriteTeamInsight: DiscoverPersonalizedInsight?
    let nextEventInsight: DiscoverPersonalizedInsight?
    let contextHeader: DiscoverActivityPanelContextHeader?

    var metricItems: [DiscoverActivityPanelItem] {
        [fansNearby, venuePlansToday, pickupPlansToday, suggestedFans]
    }
}

struct DiscoverActivityPanelPresentation: Equatable {
    var metricItems: [DiscoverActivityPanelItem]
    /// Expanded signed-in only. Favorite-team venue sentence.
    var favoriteTeamInsight: DiscoverPersonalizedInsight?
    /// Expanded signed-in only. Canonical next personal event (earliest Going venue or pickup).
    var timelyInsight: DiscoverPersonalizedInsight?
    /// Compact title + expanded summary derived from in-memory map/panel state (no geocoding).
    var contextHeader: DiscoverActivityPanelContextHeader?

    static let empty = DiscoverActivityPanelPresentation(
        metricItems: [],
        favoriteTeamInsight: nil,
        timelyInsight: nil,
        contextHeader: nil
    )

    static func signedIn(_ dashboard: DiscoverTodayDashboardPresentation) -> DiscoverActivityPanelPresentation {
        DiscoverActivityPanelPresentation(
            metricItems: dashboard.metricItems,
            favoriteTeamInsight: dashboard.favoriteTeamInsight,
            timelyInsight: dashboard.nextEventInsight,
            contextHeader: dashboard.contextHeader
        )
    }
}

/// Compact locality + one contextual summary for the Discover activity panel.
struct DiscoverActivityPanelContextHeader: Equatable {
    let title: String
    /// Optional second line — only when it adds value not already shown in the dock or metric grid.
    let summary: String?

    var accessibilityLabel: String {
        guard let summary, !summary.isEmpty else { return title }
        return "\(title). \(summary)"
    }
}

struct DiscoverActivityPanelPresentationCacheKey: Equatable {
    let isGuest: Bool
    let authId: UUID?
    let favoritesRaw: String
    let favoritesHydration: Int
    let snapshotGeneration: UInt64
    let venueFingerprint: Int
    let visibleVenueCount: Int
    let selectedDay: String
    let localToday: String
    let selectedSport: String
    let mapContentMode: String
    let pickupSubMode: String
    let mapDisplayMode: String
    let localityToken: String
    let viewedLocalityCacheToken: String
    let mapCenterBucketToken: String
    let isNearUser: Bool
    let watchSpotsShowingSport: Int
    let visiblePickupGames: Int
    let visiblePickupPlaces: Int
    let venueEventRowCount: Int
    let pickupCount: Int
    let pickupSoonCount: Int
    let venuePlansTodayCount: Int
    let pickupPlansTodayCount: Int
    let followingGoingCount: Int
    let pickupJoinCardCount: Int
    let hostedPickupCount: Int
    let suggestedFansCount: Int?
    /// Token for Fans nearby presentation (`loading` / `unavailable` / `n`).
    let fansNearbyToken: String
    let interestIDCount: Int
    let languageCode: String
}

enum DiscoverActivityPanelPresentationBuilder {
    /// Existing product rule: `FanGeoLiveEnergyTiming.startsSoonWindowMinutes` (60).
    private static let pickupStartingSoonWindow: TimeInterval =
        TimeInterval(FanGeoLiveEnergyTiming.startsSoonWindowMinutes * 60)

    private static let localDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func cacheKey(
        viewModel: MapViewModel,
        favoritesRaw: String,
        languageCode: String,
        isGuest: Bool
    ) -> DiscoverActivityPanelPresentationCacheKey {
        var venueHasher = Hasher()
        for bar in viewModel.mapVisibleBars {
            venueHasher.combine(bar.id)
        }
        let now = Date()
        let calendar = Calendar.current
        let selectedDay = ISO8601DateFormatter().string(from: calendar.startOfDay(for: viewModel.selectedDate))
        let localToday = localDayFormatter.string(from: now)
        let pickupSoon = pickupSoonCount(viewModel: viewModel, now: now)
        let venuePlansToday = myVenueGamesTodayCount(viewModel: viewModel, now: now)
        let pickupPlansToday = myPickupGamesTodayCount(viewModel: viewModel, now: now)
        let suggested = authoritativeSuggestedFansCount(viewModel: viewModel)
        let locality = resolveMapLocality(viewModel: viewModel)
        let nearUser = isMapCenterNearUser(viewModel: viewModel)
        let bounds = viewModel.currentMapRegionBounds()
        let watchSpotsSport = watchSpotsShowingSelectedSportCount(viewModel: viewModel)
        let visiblePickupGames = viewModel.pickupGamesVisibleAsMapPins(for: bounds).count
        let visiblePickupPlaces = viewModel.discoverVisiblePickupPlaceCount
        let mapCenter = viewModel.cameraPosition.region?.center
        let mapCenterBucketToken: String = {
            guard let mapCenter, CLLocationCoordinate2DIsValid(mapCenter) else { return "" }
            let bucket = MapViewModel.discoverActivityLocalityBucket(for: mapCenter)
            return "\(bucket.lat),\(bucket.lng)"
        }()
        return DiscoverActivityPanelPresentationCacheKey(
            isGuest: isGuest,
            authId: viewModel.currentUserAuthId,
            favoritesRaw: favoritesRaw,
            favoritesHydration: viewModel.favoriteTeamsHydrationGeneration,
            snapshotGeneration: viewModel.discoverMapRenderSnapshotGeneration,
            venueFingerprint: Int(truncatingIfNeeded: venueHasher.finalize()),
            visibleVenueCount: viewModel.mapVisibleBars.count,
            selectedDay: selectedDay,
            localToday: localToday,
            selectedSport: viewModel.selectedSport,
            mapContentMode: viewModel.discoverMapContentMode.rawValue,
            pickupSubMode: viewModel.discoverPickupSubMode.rawValue,
            mapDisplayMode: viewModel.mapDisplayMode.rawValue,
            localityToken: locality ?? "",
            viewedLocalityCacheToken: viewModel.discoverSettledViewedLocalityLabel ?? "",
            mapCenterBucketToken: mapCenterBucketToken,
            isNearUser: nearUser,
            watchSpotsShowingSport: watchSpotsSport,
            visiblePickupGames: visiblePickupGames,
            visiblePickupPlaces: visiblePickupPlaces,
            venueEventRowCount: viewModel.venueEventRows.count,
            pickupCount: viewModel.pickupGamesForDiscoverMap.count,
            pickupSoonCount: pickupSoon,
            venuePlansTodayCount: venuePlansToday,
            pickupPlansTodayCount: pickupPlansToday,
            followingGoingCount: viewModel.followingTabGoingItems.count,
            pickupJoinCardCount: viewModel.myPickupGameJoinRequestCards.count,
            hostedPickupCount: viewModel.myPickupGamesForSettings.count,
            suggestedFansCount: suggested,
            fansNearbyToken: fansNearbyCacheToken(viewModel: viewModel),
            interestIDCount: viewModel.venueEventInterestIDs.count
                + viewModel.followingTabUserVenueEventInterestIDs.count,
            languageCode: languageCode
        )
    }

    private static func fansNearbyCacheToken(viewModel: MapViewModel) -> String {
        guard viewModel.isLoggedIn, !viewModel.isVenueOwnerLoggedIn else { return "guest" }
        let center = viewModel.cameraPosition.region?.center
        switch FansNearbyService.shared.cachedCount(for: viewModel.currentUserAuthId, center: center) {
        case .loading: return "loading"
        case .unavailable: return "unavailable"
        case .loaded(let n): return "n:\(n)"
        }
    }

    static func build(
        viewModel: MapViewModel,
        favoritesRaw: String,
        languageCode: String,
        isGuest: Bool,
        now: Date = Date()
    ) -> DiscoverActivityPanelPresentation {
        let pickupSoon = pickupSoonCount(viewModel: viewModel, now: now)

        if isGuest {
            return DiscoverActivityPanelPresentation(
                metricItems: [
                    guestCreateAccountItem(
                        id: "fansNearby",
                        kind: .fansNearby,
                        labelKey: "discover_activity_fans_nearby",
                        supportingKey: "discover_activity_discover_local_fans_nearby",
                        systemImage: "person.2.fill",
                        languageCode: languageCode
                    ),
                    pickupSoonItem(count: pickupSoon, languageCode: languageCode),
                    guestCreateAccountItem(
                        id: "favoriteTeam",
                        kind: .favoriteTeam,
                        labelKey: "discover_activity_favorite_team",
                        supportingKey: "discover_activity_favorite_team_guest_supporting",
                        systemImage: "star.fill",
                        languageCode: languageCode
                    ),
                    guestCreateAccountItem(
                        id: "suggestedFans",
                        kind: .suggestedFans,
                        labelKey: "discover_activity_suggested_for_you",
                        supportingKey: "discover_activity_suggested_fans_guest_supporting",
                        systemImage: "person.2.badge.plus",
                        languageCode: languageCode
                    )
                ],
                favoriteTeamInsight: nil,
                timelyInsight: nil,
                contextHeader: buildContextHeader(
                    viewModel: viewModel,
                    languageCode: languageCode,
                    isGuest: true,
                    pickupSoonCount: pickupSoon
                )
            )
        }
        return .signedIn(
            buildSignedInDashboard(
                viewModel: viewModel,
                favoritesRaw: favoritesRaw,
                languageCode: languageCode,
                now: now
            )
        )
    }

    private static func buildSignedInDashboard(
        viewModel: MapViewModel,
        favoritesRaw: String,
        languageCode: String,
        now: Date
    ) -> DiscoverTodayDashboardPresentation {
        let favoriteSignal = DiscoverPersonalizedInsightBuilder.favoriteTeamVenueSignal(
            viewModel: viewModel,
            favoritesRaw: favoritesRaw,
            languageCode: languageCode
        )
        let venuePlansToday = myVenueGamesTodayCount(viewModel: viewModel, now: now)
        let pickupPlansToday = myPickupGamesTodayCount(viewModel: viewModel, now: now)

        let personalNext = DiscoverPersonalizedInsightBuilder.personalNextEventInsight(
            viewModel: viewModel,
            languageCode: languageCode,
            now: now
        )

        return DiscoverTodayDashboardPresentation(
            fansNearby: signedInFansNearbyItem(viewModel: viewModel, languageCode: languageCode),
            venuePlansToday: signedInVenuePlansTodayItem(count: venuePlansToday, languageCode: languageCode),
            pickupPlansToday: signedInPickupPlansTodayItem(count: pickupPlansToday, languageCode: languageCode),
            suggestedFans: signedInSuggestedFansMetric(viewModel: viewModel, languageCode: languageCode),
            favoriteTeamInsight: favoriteSignal?.insight,
            nextEventInsight: personalNext
                ?? DiscoverPersonalizedInsightBuilder.emptyNextEventInsight(languageCode: languageCode),
            contextHeader: buildContextHeader(
                viewModel: viewModel,
                languageCode: languageCode,
                isGuest: false,
                pickupSoonCount: 0
            )
        )
    }

    /// Going → Venue Games plan rows for local calendar today (in-memory only).
    static func myVenueGamesTodayCount(viewModel: MapViewModel, now: Date = Date()) -> Int {
        guard viewModel.isLoggedIn, !viewModel.isVenueOwnerLoggedIn else { return 0 }
        let calendar = Calendar.current
        var seen = Set<UUID>()
        for item in viewModel.followingTabGoingItems {
            guard item.isActiveGoingTabPlan else { continue }
            guard GoingTabCompletedGameVisibility.isVenueGameVisibleInGoingTab(row: item.venueEvent, now: now) else {
                continue
            }
            guard !isExcludedVenueEvent(item.venueEvent) else { continue }
            guard isVenueEventOnLocalCalendarDay(item.venueEvent, day: now, calendar: calendar) else { continue }
            seen.insert(item.id)
        }
        return seen.count
    }

    /// Approved Playing joins + Hosting rows for local calendar today (in-memory only).
    static func myPickupGamesTodayCount(viewModel: MapViewModel, now: Date = Date()) -> Int {
        guard viewModel.isLoggedIn, !viewModel.isVenueOwnerLoggedIn else { return 0 }
        let calendar = Calendar.current
        var seen = Set<UUID>()

        for card in viewModel.myPickupGameJoinRequestCards where card.pill == .approved {
            let row = viewModel.pickupGamesFollowingTabCache[card.pickupGameId]
            if let row {
                guard GoingTabCompletedGameVisibility.isPickupGameVisibleInGoingTab(row: row, now: now) else {
                    continue
                }
                let status = row.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if status == "removed" || status == "cancelled" || status == "canceled" { continue }
            }
            guard let start = PickupGameModels.parseSupabaseTimestamptz(card.game_start_at)
                    ?? row.flatMap({ PickupGameModels.parseSupabaseTimestamptz($0.game_start_at) }),
                  calendar.isDate(start, inSameDayAs: now) else {
                continue
            }
            seen.insert(card.pickupGameId)
        }

        for row in viewModel.myPickupGamesForSettings {
            guard GoingTabCompletedGameVisibility.isPickupGameVisibleInGoingTab(row: row, now: now) else {
                continue
            }
            let status = row.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if status == "removed" || status == "cancelled" || status == "canceled" { continue }
            guard let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at),
                  calendar.isDate(start, inSameDayAs: now) else {
                continue
            }
            seen.insert(row.id)
        }

        return seen.count
    }

    private static func isVenueEventOnLocalCalendarDay(
        _ row: VenueEventRow,
        day: Date,
        calendar: Calendar
    ) -> Bool {
        if let start = FanGeoLiveEnergyTiming.parseScheduledStart(row.scheduled_start_at, eventId: row.id) {
            return calendar.isDate(start, inSameDayAs: day)
        }
        let todayYMD = localDayFormatter.string(from: day)
        let eventYMD = (row.event_date ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard eventYMD.count >= 10 else { return false }
        return String(eventYMD.prefix(10)) == todayYMD
    }

    private static func isExcludedVenueEvent(_ row: VenueEventRow) -> Bool {
        DiscoverPersonalizedInsightBuilder.isExcludedVenueEventStatus(row)
    }

    private static func pickupSoonCount(viewModel: MapViewModel, now: Date) -> Int {
        viewModel.pickupGamesForDiscoverMap.reduce(into: 0) { partial, row in
            guard row.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "active" else { return }
            guard !row.hasPickupGameStarted(now: now) else { return }
            guard let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else { return }
            let delta = start.timeIntervalSince(now)
            guard delta > 0, delta <= pickupStartingSoonWindow else { return }
            partial += 1
        }
    }

    // MARK: - Context header (in-memory only)

    private static func buildContextHeader(
        viewModel: MapViewModel,
        languageCode: String,
        isGuest: Bool,
        pickupSoonCount: Int
    ) -> DiscoverActivityPanelContextHeader {
        let locale = Locale(identifier: languageCode)
        let nearUser = isMapCenterNearUser(viewModel: viewModel)
        let locality = resolveMapLocality(viewModel: viewModel)
        let title: String = {
            guard let locality, !locality.isEmpty else {
                if nearUser {
                    return L10n.t("discover_activity_context_fallback_title", languageCode: languageCode)
                }
                return L10n.t("discover_activity_context_viewing_this_area", languageCode: languageCode)
            }
            let formatKey = nearUser
                ? "discover_activity_context_nearby_in_format"
                : "discover_activity_context_viewing_format"
            return String(
                format: L10n.t(formatKey, languageCode: languageCode),
                locale: locale,
                locality
            )
        }()
        let summary = selectContextSummary(
            viewModel: viewModel,
            languageCode: languageCode,
            isGuest: isGuest,
            pickupSoonCount: pickupSoonCount
        )
        return DiscoverActivityPanelContextHeader(title: title, summary: summary)
    }

    /// Public so map-settle reverse geocode can reuse the same US state expansion.
    static func formatLocalityForDisplay(_ raw: String) -> String {
        formatLocalityDisplay(raw)
    }

    /// Prefer "Lehi, Utah" over "Lehi, UT" using in-memory US state names (no geocoding).
    private static func formatLocalityDisplay(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let parts = trimmed
            .split(separator: ",", maxSplits: 1)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = parts.first else { return trimmed }
        if parts.count == 1 {
            return expandRegionDisplayName(first)
        }
        let city = first
        let region = expandRegionDisplayName(parts[1])
        if region.isEmpty { return city }
        return "\(city), \(region)"
    }

    private static func expandRegionDisplayName(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.count == 2 {
            let code = trimmed.uppercased()
            if let name = USStatesForBusinessLocation.abbreviationsSortedByName.first(where: { $0.0 == code })?.1 {
                return name
            }
        }
        return trimmed
    }

    /// Pin-majority locality for the current viewport (no home-city fallback).
    static func pinDerivedLocality(viewModel: MapViewModel) -> String? {
        majorityLocalityFromVisiblePins(viewModel: viewModel)
    }

    private static func isMapCenterNearUser(viewModel: MapViewModel) -> Bool {
        guard let user = viewModel.currentUserLocation,
              CLLocationCoordinate2DIsValid(user),
              let center = viewModel.cameraPosition.region?.center,
              CLLocationCoordinate2DIsValid(center) else {
            // No reliable user fix: do not claim "Nearby" from profile home alone.
            return false
        }
        let userLoc = CLLocation(latitude: user.latitude, longitude: user.longitude)
        let mapLoc = CLLocation(latitude: center.latitude, longitude: center.longitude)
        return viewModel.discoverActivityPanelIsNearUser(
            distanceMeters: userLoc.distance(from: mapLoc)
        )
    }

    private static func homeCityLocality(viewModel: MapViewModel) -> String? {
        let city = viewModel.currentUserHomeCity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard city.count >= 2 else { return nil }
        let region = viewModel.currentUserHomeRegion.trimmingCharacters(in: .whitespacesAndNewlines)
        if region.isEmpty { return city }
        return formatLocalityDisplay("\(city), \(region)")
    }

    /// Viewport locality only. Never returns profile home while the map is away from the user.
    private static func resolveMapLocality(viewModel: MapViewModel) -> String? {
        let nearUser = isMapCenterNearUser(viewModel: viewModel)

        if let fromPins = majorityLocalityFromVisiblePins(viewModel: viewModel) {
            return fromPins
        }

        if let cached = viewModel.discoverSettledViewedLocalityLabel?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           cached.count >= 2 {
            return cached
        }

        // Home city is only a Nearby-mode fallback when the map is still near the user.
        if nearUser, let home = homeCityLocality(viewModel: viewModel) {
            return home
        }

        return nil
    }

    private static func majorityLocalityFromVisiblePins(viewModel: MapViewModel) -> String? {
        let bounds = viewModel.currentMapRegionBounds()
        var tallies: [String: Int] = [:]

        for place in viewModel.pickupPlacesVisibleAsMapPins(for: bounds) {
            let line = formatLocalityDisplay(place.cityStateDisplay)
            guard line.count >= 2 else { continue }
            tallies[line, default: 0] += 1
        }
        for game in viewModel.pickupGamesVisibleAsMapPins(for: bounds) {
            let city = (game.city ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard city.count >= 2 else { continue }
            let region = (game.state ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let line = region.isEmpty
                ? formatLocalityDisplay(city)
                : formatLocalityDisplay("\(city), \(region)")
            tallies[line, default: 0] += 1
        }

        guard let best = tallies.max(by: { $0.value < $1.value }), best.value >= 1 else {
            return nil
        }
        return best.key
    }

    private static func watchSpotsShowingSelectedSportCount(viewModel: MapViewModel) -> Int {
        viewModel.mapVisibleBars.reduce(into: 0) { partial, bar in
            guard viewModel.venueHasVisibleGameToday(bar) else { return }
            partial += 1
        }
    }

    /// Secondary context line — omitted when it would restate the dock status or a metric card.
    private static func selectContextSummary(
        viewModel _: MapViewModel,
        languageCode _: String,
        isGuest _: Bool,
        pickupSoonCount _: Int
    ) -> String? {
        // Counts for places / games / watch spots / fans / suggested fans already appear in the
        // Discover dock and/or the four metric cards. Prefer a one-line location title over
        // adjacent duplicate totals ("111 pickup places nearby" vs dock "111 pickup places").
        return nil
    }

    private static func guestCreateAccountItem(
        id: String,
        kind: DiscoverActivityPanelItem.Kind,
        labelKey: String,
        supportingKey: String,
        systemImage: String,
        languageCode: String
    ) -> DiscoverActivityPanelItem {
        let label = L10n.t(labelKey, languageCode: languageCode)
        let value = L10n.t("discover_activity_create_account", languageCode: languageCode)
        let supporting = L10n.t(supportingKey, languageCode: languageCode)
        return DiscoverActivityPanelItem(
            id: id,
            kind: kind,
            valueText: value,
            labelText: label,
            supportingText: metricSupportingTextIfFits(supporting),
            systemImage: systemImage,
            accessibilityLabel: "\(label). \(value). \(supporting)",
            isTappable: true,
            valueUsesMonospacedDigits: false
        )
    }

    /// Always returns a card so signed-in compact layout stays four equal columns.
    private static func signedInFansNearbyItem(
        viewModel: MapViewModel,
        languageCode: String
    ) -> DiscoverActivityPanelItem {
        let label = L10n.t("discover_activity_fans_nearby", languageCode: languageCode)
        let center = viewModel.cameraPosition.region?.center
        switch FansNearbyService.shared.cachedCount(for: viewModel.currentUserAuthId, center: center) {
        case .loading, .unavailable:
            let unavailable = L10n.t("discover_activity_fans_nearby_unavailable", languageCode: languageCode)
            return DiscoverActivityPanelItem(
                id: "fansNearby",
                kind: .fansNearby,
                valueText: "—",
                labelText: label,
                supportingText: metricSupportingTextIfFits(unavailable),
                systemImage: "person.2.fill",
                accessibilityLabel: "\(label). \(unavailable)",
                isTappable: false,
                valueUsesMonospacedDigits: false
            )
        case .loaded(let count):
            let a11y: String = {
                if count == 0 {
                    return L10n.t("discover_activity_fans_nearby_a11y_zero", languageCode: languageCode)
                }
                if count == 1 {
                    return L10n.t("discover_activity_fans_nearby_a11y_one", languageCode: languageCode)
                }
                return String(
                    format: L10n.t("discover_activity_fans_nearby_a11y_other_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    count
                )
            }()
            // Zero-count coaching copy is too long for the four-column metric grid; VoiceOver
            // already announces `discover_activity_fans_nearby_a11y_zero`. Prefer omit over clip.
            return DiscoverActivityPanelItem(
                id: "fansNearby",
                kind: .fansNearby,
                valueText: "\(count)",
                labelText: label,
                supportingText: nil,
                systemImage: "person.2.fill",
                accessibilityLabel: a11y,
                isTappable: count > 0,
                valueUsesMonospacedDigits: true
            )
        }
    }

    private static func signedInVenuePlansTodayItem(count: Int, languageCode: String) -> DiscoverActivityPanelItem {
        let label = L10n.t("discover_activity_my_venue_games_today", languageCode: languageCode)
        let a11y: String = {
            if count == 1 {
                return L10n.t("discover_activity_my_venue_games_today_a11y_one", languageCode: languageCode)
            }
            return String(
                format: L10n.t("discover_activity_my_venue_games_today_a11y_other_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                count
            )
        }()
        return DiscoverActivityPanelItem(
            id: "venuePlansToday",
            kind: .venuePlansToday,
            valueText: "\(count)",
            labelText: label,
            supportingText: nil,
            systemImage: "tv.fill",
            accessibilityLabel: a11y,
            isTappable: true,
            valueUsesMonospacedDigits: true
        )
    }

    private static func signedInPickupPlansTodayItem(count: Int, languageCode: String) -> DiscoverActivityPanelItem {
        let label = L10n.t("discover_activity_my_pickup_games_today", languageCode: languageCode)
        let a11y: String = {
            if count == 1 {
                return L10n.t("discover_activity_my_pickup_games_today_a11y_one", languageCode: languageCode)
            }
            return String(
                format: L10n.t("discover_activity_my_pickup_games_today_a11y_other_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                count
            )
        }()
        return DiscoverActivityPanelItem(
            id: "pickupPlansToday",
            kind: .pickupPlansToday,
            valueText: "\(count)",
            labelText: label,
            supportingText: nil,
            systemImage: "figure.run",
            accessibilityLabel: a11y,
            isTappable: true,
            valueUsesMonospacedDigits: true
        )
    }

    private static func pickupSoonItem(count: Int, languageCode: String) -> DiscoverActivityPanelItem {
        let label = L10n.t("discover_activity_pickup_soon", languageCode: languageCode)
        let a11y: String = {
            if count == 0 {
                return L10n.t("discover_activity_pickup_soon_none", languageCode: languageCode)
            }
            return String(
                format: L10n.t("discover_activity_pickup_soon_a11y_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                count
            )
        }()
        return DiscoverActivityPanelItem(
            id: "pickupSoon",
            kind: .pickupSoon,
            valueText: "\(count)",
            labelText: label,
            supportingText: nil,
            systemImage: "figure.run",
            accessibilityLabel: a11y,
            isTappable: false,
            valueUsesMonospacedDigits: true
        )
    }

    private static func signedInSuggestedFansMetric(
        viewModel: MapViewModel,
        languageCode: String
    ) -> DiscoverActivityPanelItem {
        let label = L10n.t("discover_activity_suggested_for_you", languageCode: languageCode)
        if let count = authoritativeSuggestedFansCount(viewModel: viewModel) {
            let valueText = count >= 100 ? "99+" : "\(count)"
            let a11y: String = {
                if count == 1 {
                    return L10n.t("discover_activity_suggested_fans_a11y_one", languageCode: languageCode)
                }
                return String(
                    format: L10n.t("discover_activity_suggested_fans_a11y_other_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    min(count, 99)
                )
            }()
            return DiscoverActivityPanelItem(
                id: "suggestedFans",
                kind: .suggestedFans,
                valueText: valueText,
                labelText: label,
                supportingText: nil,
                systemImage: "person.2.badge.plus",
                accessibilityLabel: a11y,
                isTappable: true,
                valueUsesMonospacedDigits: true
            )
        }
        let unavailable = L10n.t("discover_activity_fan_matches_unavailable", languageCode: languageCode)
        return DiscoverActivityPanelItem(
            id: "suggestedFans",
            kind: .suggestedFans,
            valueText: "—",
            labelText: label,
            supportingText: metricSupportingTextIfFits(unavailable),
            systemImage: "person.2.badge.plus",
            accessibilityLabel: "\(label). \(unavailable)",
            isTappable: true,
            valueUsesMonospacedDigits: false
        )
    }

    /// Narrow metric columns cannot show long coaching copy without clipping — omit rather than truncate.
    private static func metricSupportingTextIfFits(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // ~1/4 phone width at ~9.5–11pt: keep only short complete lines.
        return trimmed.count <= 34 ? trimmed : nil
    }

    /// Authoritative Suggested Fans cache only — never Discover-triggered fetch.
    /// Preserves last loaded value even if TTL has elapsed (stale-while-revalidate display).
    private static func authoritativeSuggestedFansCount(viewModel: MapViewModel) -> Int? {
        guard let authId = viewModel.currentUserAuthId else { return nil }
        guard ProfilePhase1PersonalizationCache.suggestedFansLoadedAtByAuthId[authId] != nil else {
            return nil
        }
        return ProfilePhase1PersonalizationCache.suggestedFansByAuthId[authId]?.count ?? 0
    }
}

// MARK: - Personalized insight (precomputed value + concrete leaf row)

struct DiscoverPersonalizedInsight: Equatable {
    enum Kind: String, Equatable {
        case favoriteTeamVenue
        case pickup
        case going
        case empty
    }

    let kind: Kind
    let primaryText: String
    let supportingText: String?
    let systemImage: String
    /// When set, shown instead of ``systemImage`` (sport / calendar emoji).
    let leadingEmoji: String?
    /// Next-event only: relative countdown line (`Today`, `In 13 days`).
    let relativeCountdownText: String?
    /// Next-event only: absolute date + time (`Jul 29 • 8:23 AM`).
    let absoluteTimeText: String?
    /// Next-event only: in-memory location label when already available.
    let locationText: String?
    /// Next-event only: additional eligible upcoming events beyond the displayed one (`total - 1`).
    let moreUpcomingCount: Int
    /// Next-event only: compact trailing indicator such as `+2 more` when ``moreUpcomingCount`` > 0.
    let moreUpcomingText: String?
    /// Pickup game id for existing Discover detail sheet navigation.
    let destinationPickupGameId: UUID?
    /// Venue id for existing venue preview selection when present in memory.
    let destinationVenueId: UUID?
    let accessibilityLabel: String
    /// Safe analytics bucket only (`1`, `2_3`, `4_9`, `10_plus`). Never team/venue IDs.
    let countBucket: String

    var isNextEventTappable: Bool {
        kind == .going || kind == .pickup
    }

    init(
        kind: Kind,
        primaryText: String,
        supportingText: String?,
        systemImage: String,
        leadingEmoji: String? = nil,
        relativeCountdownText: String? = nil,
        absoluteTimeText: String? = nil,
        locationText: String? = nil,
        moreUpcomingCount: Int = 0,
        moreUpcomingText: String? = nil,
        destinationPickupGameId: UUID? = nil,
        destinationVenueId: UUID? = nil,
        accessibilityLabel: String,
        countBucket: String
    ) {
        self.kind = kind
        self.primaryText = primaryText
        self.supportingText = supportingText
        self.systemImage = systemImage
        self.leadingEmoji = leadingEmoji
        self.relativeCountdownText = relativeCountdownText
        self.absoluteTimeText = absoluteTimeText
        self.locationText = locationText
        self.moreUpcomingCount = max(0, moreUpcomingCount)
        self.moreUpcomingText = moreUpcomingText
        self.destinationPickupGameId = destinationPickupGameId
        self.destinationVenueId = destinationVenueId
        self.accessibilityLabel = accessibilityLabel
        self.countBucket = countBucket
    }
}

/// Compact favorite-team metric + expanded insight, from one scoped recompute.
struct DiscoverFavoriteTeamVenueSignal: Equatable {
    let venueCount: Int
    let teamName: String
    let insight: DiscoverPersonalizedInsight
}

/// Kept for call-site clarity; presentation builder owns the combined cache key.
typealias DiscoverPersonalizedInsightCacheKey = DiscoverActivityPanelPresentationCacheKey

enum DiscoverPersonalizedInsightBuilder {
    private static let pickupStartingSoonWindow: TimeInterval =
        TimeInterval(FanGeoLiveEnergyTiming.startsSoonWindowMinutes * 60)

    static func favoriteTeamVenueInsight(
        viewModel: MapViewModel,
        favoritesRaw: String,
        languageCode: String
    ) -> DiscoverPersonalizedInsight? {
        favoriteTeamVenueSignal(
            viewModel: viewModel,
            favoritesRaw: favoritesRaw,
            languageCode: languageCode
        )?.insight
    }

    /// Favorite-team venue signal for the current visible map scope / day / sport.
    static func favoriteTeamVenueSignal(
        viewModel: MapViewModel,
        favoritesRaw: String,
        languageCode: String
    ) -> DiscoverFavoriteTeamVenueSignal? {
        guard viewModel.isLoggedIn, !viewModel.isVenueOwnerLoggedIn else { return nil }

        let favoriteIDs = FavoriteTeamsStore.decodeIDs(from: favoritesRaw)
        guard !favoriteIDs.isEmpty else { return nil }
        let favoriteIDSet = Set(favoriteIDs)
        let visibleBars = viewModel.mapVisibleBars
        guard !visibleBars.isEmpty else { return nil }

        let teamIDIndex = ManualVenueTeamResolver.exactNormalizedTeamIDIndex()

        var venueIDsByTeam: [String: Set<UUID>] = [:]
        var earliestStartByTeam: [String: Date] = [:]

        for bar in visibleBars {
            let dayEvents = viewModel.selectedDayEventsForMap(bar)
            guard !dayEvents.isEmpty else { continue }

            var matchedFavoriteIDsForVenue = Set<String>()
            var earliestForVenueFavorites: [String: Date] = [:]

            for event in dayEvents {
                guard let row = viewModel.cachedVenueEventRow(for: bar, gameTitle: event.title) else {
                    continue
                }
                if isExcludedVenueEvent(row) { continue }

                let start = FanGeoLiveEnergyTiming.parseScheduledStart(row.scheduled_start_at, eventId: row.id)
                    ?? event.date

                for rawName in [row.home_team, row.away_team] {
                    guard let rawName else { continue }
                    guard let resolved = ManualVenueTeamResolver.exactFavoriteTeam(
                        for: rawName,
                        index: teamIDIndex
                    ) else {
                        continue
                    }
                    guard favoriteIDSet.contains(resolved.id) else { continue }
                    matchedFavoriteIDsForVenue.insert(resolved.id)
                    if let existing = earliestForVenueFavorites[resolved.id] {
                        if start < existing { earliestForVenueFavorites[resolved.id] = start }
                    } else {
                        earliestForVenueFavorites[resolved.id] = start
                    }
                }
            }

            for teamID in matchedFavoriteIDsForVenue {
                venueIDsByTeam[teamID, default: []].insert(bar.id)
                if let start = earliestForVenueFavorites[teamID] {
                    if let existing = earliestStartByTeam[teamID] {
                        if start < existing { earliestStartByTeam[teamID] = start }
                    } else {
                        earliestStartByTeam[teamID] = start
                    }
                }
            }
        }

        guard !venueIDsByTeam.isEmpty else { return nil }

        let favoriteOrder = Dictionary(uniqueKeysWithValues: favoriteIDs.enumerated().map { ($0.element, $0.offset) })
        let ranked = venueIDsByTeam.keys.sorted { lhs, rhs in
            let lhsCount = venueIDsByTeam[lhs]?.count ?? 0
            let rhsCount = venueIDsByTeam[rhs]?.count ?? 0
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            let lhsStart = earliestStartByTeam[lhs] ?? .distantFuture
            let rhsStart = earliestStartByTeam[rhs] ?? .distantFuture
            if lhsStart != rhsStart { return lhsStart < rhsStart }
            let lhsOrder = favoriteOrder[lhs] ?? Int.max
            let rhsOrder = favoriteOrder[rhs] ?? Int.max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return lhs < rhs
        }

        guard let winnerID = ranked.first,
              let venueCount = venueIDsByTeam[winnerID]?.count,
              venueCount > 0,
              let team = FavoriteTeamCatalog.team(id: winnerID) else {
            return nil
        }

        let primaryKey = venueCount == 1
            ? "discover_insight_places_showing_team_today_one_format"
            : "discover_insight_places_showing_team_today_other_format"
        let primary = String(
            format: L10n.t(primaryKey, languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            venueCount,
            team.name
        )
        let supporting = L10n.t("discover_insight_based_on_favorite_team", languageCode: languageCode)
        let insight = DiscoverPersonalizedInsight(
            kind: .favoriteTeamVenue,
            primaryText: primary,
            supportingText: supporting,
            systemImage: "star.fill",
            accessibilityLabel: "\(primary). \(supporting)",
            countBucket: countBucket(venueCount)
        )
        return DiscoverFavoriteTeamVenueSignal(
            venueCount: venueCount,
            teamName: team.name,
            insight: insight
        )
    }

    static func isExcludedVenueEventStatus(_ row: VenueEventRow) -> Bool {
        let status = (row.admin_status ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if status.isEmpty || status == "active" { return false }
        switch status {
        case "canceled", "cancelled", "deleted", "rejected", "hidden", "inactive":
            return true
        default:
            return false
        }
    }

    private static func isExcludedVenueEvent(_ row: VenueEventRow) -> Bool {
        isExcludedVenueEventStatus(row)
    }

    /// Soonest upcoming personal Going venue event or approved/hosted pickup (in-memory).
    /// Merges both sources by actual start time — never prefers pickup over venue (or vice versa).
    static func personalNextEventInsight(
        viewModel: MapViewModel,
        languageCode: String,
        now: Date
    ) -> DiscoverPersonalizedInsight? {
        guard viewModel.isLoggedIn, !viewModel.isVenueOwnerLoggedIn else { return nil }

        var candidates: [PersonalNextEventCandidate] = []
        candidates.reserveCapacity(
            viewModel.followingTabGoingItems.count
                + viewModel.myPickupGameJoinRequestCards.count
                + viewModel.myPickupGamesForSettings.count
        )
        var seenVenueEventIds = Set<UUID>()
        var seenPickupIds = Set<UUID>()

        for item in viewModel.followingTabGoingItems where item.isActiveGoingTabPlan {
            let row = item.venueEvent
            guard !isExcludedVenueEvent(row) else { continue }
            guard GoingTabCompletedGameVisibility.isVenueGameVisibleInGoingTab(row: row, now: now) else {
                continue
            }
            guard let start = FanGeoLiveEnergyTiming.parseScheduledStart(row.scheduled_start_at, eventId: row.id),
                  start > now else {
                continue
            }
            guard seenVenueEventIds.insert(item.id).inserted else { continue }
            candidates.append(
                PersonalNextEventCandidate(
                    start: start,
                    title: venueEventDisplayTitle(row),
                    sport: row.sport ?? "",
                    kind: .going,
                    location: trimmedLocation(row.venue_name) ?? trimmedLocation(item.bar.name),
                    pickupGameId: nil,
                    venueId: row.venue_id ?? item.bar.id,
                    tieBreakId: item.id
                )
            )
        }

        for card in viewModel.myPickupGameJoinRequestCards where card.pill == .approved {
            guard let start = PickupGameModels.parseSupabaseTimestamptz(card.game_start_at), start > now else {
                continue
            }
            if let row = viewModel.pickupGamesFollowingTabCache[card.pickupGameId],
               !GoingTabCompletedGameVisibility.isPickupGameVisibleInGoingTab(row: row, now: now) {
                continue
            }
            if let row = viewModel.pickupGamesFollowingTabCache[card.pickupGameId] {
                let status = row.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if status == "removed" || status == "cancelled" || status == "canceled" { continue }
            }
            guard seenPickupIds.insert(card.pickupGameId).inserted else { continue }
            let cached = viewModel.pickupGamesFollowingTabCache[card.pickupGameId]
            let sport = cached?.sport ?? card.sport
            let location = trimmedLocation(card.locationLine)
                ?? pickupLocationFromRow(cached)
            candidates.append(
                PersonalNextEventCandidate(
                    start: start,
                    title: pickupEventDisplayTitle(sport: sport, fallbackTitle: card.title),
                    sport: sport,
                    kind: .pickup,
                    location: location,
                    pickupGameId: card.pickupGameId,
                    venueId: nil,
                    tieBreakId: card.pickupGameId
                )
            )
        }

        for row in viewModel.myPickupGamesForSettings {
            guard GoingTabCompletedGameVisibility.isPickupGameVisibleInGoingTab(row: row, now: now) else {
                continue
            }
            let status = row.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if status == "removed" || status == "cancelled" || status == "canceled" { continue }
            guard let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at), start > now else {
                continue
            }
            guard seenPickupIds.insert(row.id).inserted else { continue }
            candidates.append(
                PersonalNextEventCandidate(
                    start: start,
                    title: pickupEventDisplayTitle(sport: row.sport, fallbackTitle: row.title),
                    sport: row.sport,
                    kind: .pickup,
                    location: pickupLocationFromRow(row),
                    pickupGameId: row.id,
                    venueId: nil,
                    tieBreakId: row.id
                )
            )
        }

        guard !candidates.isEmpty else { return nil }

        candidates.sort { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            // Stable deterministic tie-break only for this card — does not alter Going/list ordering.
            if lhs.kind != rhs.kind {
                return lhs.kind == .going
            }
            return lhs.tieBreakId.uuidString < rhs.tieBreakId.uuidString
        }

        let best = candidates[0]
        let moreCount = candidates.count - 1
        return makeNextEventInsight(
            from: best,
            moreUpcomingCount: moreCount,
            languageCode: languageCode,
            now: now
        )
    }

    static func emptyNextEventInsight(languageCode: String) -> DiscoverPersonalizedInsight {
        let primary = L10n.t("discover_insight_no_upcoming_events", languageCode: languageCode)
        return DiscoverPersonalizedInsight(
            kind: .empty,
            primaryText: primary,
            supportingText: L10n.t("discover_insight_find_your_next_game", languageCode: languageCode),
            systemImage: "calendar",
            leadingEmoji: "📅",
            accessibilityLabel: primary,
            countBucket: "0"
        )
    }

    private struct PersonalNextEventCandidate {
        let start: Date
        let title: String
        let sport: String
        let kind: DiscoverPersonalizedInsight.Kind
        let location: String?
        let pickupGameId: UUID?
        let venueId: UUID?
        let tieBreakId: UUID
    }

    private static func makeNextEventInsight(
        from candidate: PersonalNextEventCandidate,
        moreUpcomingCount: Int,
        languageCode: String,
        now: Date
    ) -> DiscoverPersonalizedInsight {
        let emoji = sportEmoji(for: candidate.sport)
        let relative = relativeCountdownLabel(for: candidate.start, now: now)
        let absolute = absoluteDateTimeLabel(for: candidate.start, languageCode: languageCode)
        let supporting = [relative, absolute].joined(separator: " • ")
        let moreText: String? = moreUpcomingCount > 0
            ? String(
                format: L10n.t("discover_insight_more_upcoming_compact_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                moreUpcomingCount
            )
            : nil
        var a11yParts = [candidate.title, relative, absolute]
        if let location = candidate.location, !location.isEmpty {
            a11yParts.append(location)
        }
        if moreUpcomingCount > 0 {
            a11yParts.append(
                String(
                    format: L10n.t("discover_insight_more_upcoming_a11y_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    moreUpcomingCount
                )
            )
        }
        return DiscoverPersonalizedInsight(
            kind: candidate.kind,
            primaryText: candidate.title,
            supportingText: supporting,
            systemImage: candidate.kind == .pickup ? "figure.run" : "checkmark.circle.fill",
            leadingEmoji: emoji,
            relativeCountdownText: relative,
            absoluteTimeText: absolute,
            locationText: candidate.location,
            moreUpcomingCount: moreUpcomingCount,
            moreUpcomingText: moreText,
            destinationPickupGameId: candidate.pickupGameId,
            destinationVenueId: candidate.venueId,
            accessibilityLabel: a11yParts.joined(separator: ". "),
            countBucket: countBucket(moreUpcomingCount + 1)
        )
    }

    private static func trimmedLocation(_ raw: String?) -> String? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private static func pickupLocationFromRow(_ row: PickupGameRow?) -> String? {
        guard let row else { return nil }
        let address = row.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !address.isEmpty { return address }
        let city = row.city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let state = row.state?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !city.isEmpty, !state.isEmpty { return "\(city), \(state)" }
        if !city.isEmpty { return city }
        return nil
    }

    private static func venueEventDisplayTitle(_ row: VenueEventRow) -> String {
        let home = row.home_team?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let away = row.away_team?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !home.isEmpty, !away.isEmpty {
            return "\(home) vs \(away)"
        }
        let title = row.event_title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty { return title }
        return "Venue game"
    }

    private static func pickupEventDisplayTitle(sport: String, fallbackTitle: String) -> String {
        let sportLabel = AppSportCatalog.displayLabel(forSportToken: sport)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !sportLabel.isEmpty,
           sportLabel.caseInsensitiveCompare("Sports") != .orderedSame,
           sportLabel.caseInsensitiveCompare("All") != .orderedSame {
            return "Pickup \(sportLabel)"
        }
        let title = fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        return "Pickup game"
    }

    private static func sportEmoji(for sport: String) -> String {
        let emoji = SportFilterCatalog.resolve(sport).emoji
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return emoji.isEmpty ? SportFilterCatalog.fallbackEmoji : emoji
    }

    /// Relative countdown for the next-event card (`Today` / `Tomorrow` / `In X days`).
    private static func relativeCountdownLabel(for start: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(start) {
            return "Today"
        }
        if calendar.isDateInTomorrow(start) {
            return "Tomorrow"
        }
        let today = calendar.startOfDay(for: now)
        let target = calendar.startOfDay(for: start)
        let daysAhead = max(1, calendar.dateComponents([.day], from: today, to: target).day ?? 1)
        return "In \(daysAhead) days"
    }

    private static func absoluteDateTimeLabel(for start: Date, languageCode: String) -> String {
        let locale = Locale(identifier: languageCode)
        let day = start.formatted(
            Date.FormatStyle()
                .month(.abbreviated)
                .day()
                .locale(locale)
        )
        return "\(day) • \(shortTimeLabel(for: start, languageCode: languageCode))"
    }

    private static func shortTimeLabel(for start: Date, languageCode: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: languageCode)
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: start)
    }

    static func pickupInsight(
        viewModel: MapViewModel,
        languageCode: String,
        now: Date
    ) -> DiscoverPersonalizedInsight? {
        guard viewModel.isLoggedIn, !viewModel.isVenueOwnerLoggedIn else { return nil }
        var soonest: Date?
        for row in viewModel.pickupGamesForDiscoverMap {
            guard row.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "active" else {
                continue
            }
            guard !row.hasPickupGameStarted(now: now) else { continue }
            guard let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else { continue }
            let delta = start.timeIntervalSince(now)
            guard delta > 0, delta <= pickupStartingSoonWindow else { continue }
            if let existing = soonest {
                if start < existing { soonest = start }
            } else {
                soonest = start
            }
        }
        guard let start = soonest else { return nil }
        let duration = localizedRelativeDuration(from: now, to: start, languageCode: languageCode)
        let primary = String(
            format: L10n.t("discover_insight_pickup_starts_in_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            duration
        )
        return DiscoverPersonalizedInsight(
            kind: .pickup,
            primaryText: primary,
            supportingText: nil,
            systemImage: "figure.run",
            accessibilityLabel: primary,
            countBucket: "1"
        )
    }

    static func goingInsight(
        viewModel: MapViewModel,
        languageCode: String,
        now: Date
    ) -> DiscoverPersonalizedInsight? {
        guard viewModel.isLoggedIn, !viewModel.isVenueOwnerLoggedIn else { return nil }
        var soonest: Date?
        for bar in viewModel.mapVisibleBars {
            for event in viewModel.selectedDayEventsForMap(bar) {
                guard let row = viewModel.cachedVenueEventRow(for: bar, gameTitle: event.title),
                      let eventID = row.id else {
                    continue
                }
                if isExcludedVenueEvent(row) { continue }
                guard viewModel.isInterestedInVenueEvent(eventID) else { continue }
                let start = FanGeoLiveEnergyTiming.parseScheduledStart(row.scheduled_start_at, eventId: row.id)
                    ?? event.date
                guard start > now else { continue }
                if let existing = soonest {
                    if start < existing { soonest = start }
                } else {
                    soonest = start
                }
            }
        }
        guard let start = soonest else { return nil }
        let duration = localizedRelativeDuration(from: now, to: start, languageCode: languageCode)
        let primary = String(
            format: L10n.t("discover_insight_next_event_starts_in_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            duration
        )
        return DiscoverPersonalizedInsight(
            kind: .going,
            primaryText: primary,
            supportingText: nil,
            systemImage: "checkmark.circle.fill",
            accessibilityLabel: primary,
            countBucket: "1"
        )
    }

    private static func localizedRelativeDuration(
        from now: Date,
        to start: Date,
        languageCode: String
    ) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = .abbreviated
        formatter.calendar = Calendar.current
        formatter.calendar?.locale = Locale(identifier: languageCode)
        let seconds = max(60, start.timeIntervalSince(now))
        return formatter.string(from: seconds) ?? "\(Int(ceil(seconds / 60)))m"
    }

    static func countBucket(_ count: Int) -> String {
        switch count {
        case ...0: return "0"
        case 1: return "1"
        case 2...3: return "2_3"
        case 4...9: return "4_9"
        default: return "10_plus"
        }
    }

    static func analyticsTypeToken(for kind: DiscoverPersonalizedInsight.Kind) -> String {
        switch kind {
        case .favoriteTeamVenue: return "favorite_team_venue"
        case .pickup: return "pickup"
        case .going: return "going"
        case .empty: return "empty"
        }
    }
}

/// Concrete non-generic leaf — plain value props only (no `@ViewBuilder` slots).
struct DiscoverPersonalizedInsightRow: View {
    let insight: DiscoverPersonalizedInsight
    var onTap: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    private var isNextEventCard: Bool {
        insight.kind == .going || insight.kind == .pickup || insight.kind == .empty
    }

    var body: some View {
        Group {
            if isNextEventCard {
                nextEventCard
            } else {
                favoriteTeamRow
            }
        }
    }

    private var favoriteTeamRow: some View {
        HStack(alignment: .center, spacing: 8) {
            leadingIcon
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(insight.primaryText)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)

                if let supporting = insight.supportingText, !supporting.isEmpty {
                    Text(supporting)
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(insight.accessibilityLabel)
    }

    private var nextEventCard: some View {
        let content = HStack(alignment: .top, spacing: FGSpacing.sm) {
            leadingIcon
                .frame(width: 22, height: 22, alignment: .center)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: FGSpacing.xs) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: FGSpacing.sm) {
                        nextEventTitleText
                        nextEventMoreUpcomingCapsule
                        nextEventChevron
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top, spacing: FGSpacing.sm) {
                            nextEventTitleText
                            nextEventChevron
                        }
                        nextEventMoreUpcomingCapsule
                    }
                }

                if let relative = insight.relativeCountdownText, !relative.isEmpty {
                    Text(relative)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let supporting = insight.supportingText, !supporting.isEmpty {
                    Text(supporting)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let absolute = insight.absoluteTimeText, !absolute.isEmpty {
                    Text(absolute)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let location = insight.locationText, !location.isEmpty {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "mappin")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(FGColor.mutedText(colorScheme))
                            .padding(.top, 1)
                            .accessibilityHidden(true)
                        Text(location)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(FGColor.mutedText(colorScheme))
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, FGSpacing.sm + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 44, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(FGAdaptiveSurface.controlFill.opacity(colorScheme == .dark ? 0.55 : 0.78))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.55), lineWidth: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(insight.accessibilityLabel)

        return Group {
            if insight.isNextEventTappable, let onTap {
                Button(action: onTap) {
                    content
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
            } else {
                content
            }
        }
    }

    private var nextEventTitleText: some View {
        Text(insight.primaryText)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(FGColor.primaryText(colorScheme))
            .multilineTextAlignment(.leading)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
    }

    @ViewBuilder
    private var nextEventMoreUpcomingCapsule: some View {
        if let more = insight.moreUpcomingText, !more.isEmpty {
            Text(more)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.35 : 0.22))
                )
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var nextEventChevron: some View {
        if insight.isNextEventTappable {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .padding(.top, 2)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if let emoji = insight.leadingEmoji, !emoji.isEmpty {
            Text(emoji)
                .font(.system(size: 15))
        } else {
            Image(systemName: insight.systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(FGColor.accentBlue)
        }
    }
}

/// Compact guest CTA leaf — plain value props only (no `@ViewBuilder` slots).
struct DiscoverActivityGuestCTARow: View {
    let title: String
    let supportingText: String
    let buttonTitle: String
    let onCreateAccount: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "star.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(FGColor.accentYellow)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(supportingText)
                        .font(FGTypography.metadata.weight(.medium))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)

            Button(action: onCreateAccount) {
                Text(buttonTitle)
                    .font(FGTypography.caption.weight(.heavy))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(FGColor.brandGradient)
                    .clipShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(buttonTitle)
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DiscoverActivityPanel: View {
    let presentation: DiscoverActivityPanelPresentation
    /// Guest fan (signed out): Fans nearby teaser + identity + expanded CTA.
    var isGuestMode: Bool = false
    var onGuestCreateAccount: () -> Void = {}
    /// Signed-in metric destinations (Going / Account). Unused in guest mode.
    var onMetricTap: (DiscoverActivityPanelItem.Kind) -> Void = { _ in }
    /// Signed-in next-event row tap. Unused for empty / favorite insights.
    var onNextEventTap: (DiscoverPersonalizedInsight) -> Void = { _ in }
    @Binding var state: DiscoverActivityPanelState
    let languageCode: String
    var accountUserId: UUID? = nil
    var onUserInteracted: () -> Void = {}
    /// First-Discover instructional line (expanded only). Cleared when intro is completed.
    var showsIntroInstruction: Bool = false
    /// Increment to fire a single neutral→green→neutral handle attention pulse.
    var handleAttentionToken: UInt = 0

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @GestureState private var dragTranslation: CGFloat = 0
    @State private var handleEmphasized = false
    @State private var handlePulseTask: Task<Void, Never>?
    @State private var handleBreathScale: CGFloat = 1
    @State private var handleBreathOpacity: Double = 0.88
    @State private var handleBreathTask: Task<Void, Never>?

    private var isHidden: Bool { state == .hidden }
    private var isExpanded: Bool { state == .expanded }
    private var isCompact: Bool { state == .compact }
    private var showsGuestCTA: Bool {
        isGuestMode && isExpanded
    }
    private var showsExpandedIntroInstruction: Bool {
        showsIntroInstruction && isExpanded
    }

    private var isDraggingHandle: Bool {
        abs(dragTranslation) > 0.5
    }

    private var handleGradient: LinearGradient {
        LinearGradient(
            colors: [
                FGColor.accentBlue.opacity(handleEmphasized ? 0.95 : handleBreathOpacity),
                FGColor.gradientEnd.opacity(handleEmphasized ? 0.92 : max(0.78, handleBreathOpacity - 0.04))
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var grabHandleCapsule: some View {
        Group {
            if handleEmphasized {
                Capsule(style: .continuous)
                    .fill(FGColor.accentGreen.opacity(0.90))
            } else {
                Capsule(style: .continuous)
                    .fill(handleGradient)
            }
        }
        .frame(width: 38, height: 5.5)
        .shadow(color: FGColor.accentBlue.opacity(0.22), radius: 2.5, y: 1)
        .scaleEffect(handleEmphasized ? 1.0 : handleBreathScale)
        .opacity(isHidden ? 0.72 : 1)
        .accessibilityHidden(true)
    }

    var body: some View {
        Group {
            if isHidden {
                hiddenHandle
            } else {
                visiblePanel
            }
        }
        .animation(panelAnimation, value: state)
        .animation(panelAnimation, value: presentation)
        .onAppear {
            startHandleBreathingLoop()
        }
        .onChange(of: handleAttentionToken) { _, token in
            guard token > 0 else { return }
            runHandleAttentionPulse()
        }
        .onChange(of: dragTranslation) { _, _ in
            if isDraggingHandle {
                resetHandleBreathVisuals()
            }
        }
        .onDisappear {
            handlePulseTask?.cancel()
            handlePulseTask = nil
            handleBreathTask?.cancel()
            handleBreathTask = nil
            handleEmphasized = false
            resetHandleBreathVisuals()
        }
    }

    /// Tiny handle only — no card / body that could intercept map touches.
    private var hiddenHandle: some View {
        Color.clear
            .frame(height: 12)
            .frame(maxWidth: .infinity)
            .overlay {
                Button {
                    onUserInteracted()
                    setState(.compact, analyticsSource: "tapHiddenHandle")
                } label: {
                    grabHandleCapsule
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .highPriorityGesture(hiddenDragGesture)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.t("discover_activity_hidden_a11y", languageCode: languageCode))
            .accessibilityHint(L10n.t("discover_activity_show_hint", languageCode: languageCode))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: Text(L10n.t("discover_activity_show_hint", languageCode: languageCode))) {
                onUserInteracted()
                setState(.compact, analyticsSource: "a11yShow")
            }
            .dynamicTypeSize(.large)
    }

    private var visiblePanel: some View {
        VStack(spacing: 0) {
            grabHandleCapsule
                .padding(.top, isExpanded ? 8 : 6)
                .padding(.bottom, isExpanded ? 6 : 4)

            if let header = presentation.contextHeader {
                contextHeaderView(header, showSummary: isExpanded)
                    .padding(.horizontal, isExpanded ? 12 : 14)
                    .padding(.bottom, isExpanded ? 8 : 4)
            }

            Group {
                if isExpanded {
                    expandedContent
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                } else {
                    compactContent
                        .transition(reduceMotion ? .opacity : .opacity)
                }
            }
            .padding(.horizontal, isExpanded ? 10 : 14)
            .padding(.bottom, isExpanded ? 10 : 8)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: visiblePanelMinHeight, maxHeight: visiblePanelMaxHeight)
        .fanGeoGlassCard(cornerRadius: isExpanded ? 20 : 28)
        .offset(y: visibleDragOffset)
        .contentShape(Rectangle())
        .highPriorityGesture(visibleDragGesture)
        .onTapGesture {
            guard isCompact else { return }
            onUserInteracted()
            setState(.expanded, analyticsSource: "tapCompact")
        }
        .accessibilityElement(children: isExpanded ? .contain : .combine)
        .accessibilityLabel(
            isExpanded
                ? L10n.t("discover_activity_summary_a11y", languageCode: languageCode)
                : compactAccessibilityLabel
        )
        .accessibilityHint(
            L10n.t(
                isExpanded ? "discover_activity_collapse_hint" : "discover_activity_expand_hint",
                languageCode: languageCode
            )
        )
        .accessibilityAddTraits(isExpanded ? [] : .isButton)
        .accessibilityAction(named: Text(
            L10n.t(
                isExpanded ? "discover_activity_collapse_hint" : "discover_activity_expand_hint",
                languageCode: languageCode
            )
        )) {
            onUserInteracted()
            setState(isExpanded ? .compact : .expanded, analyticsSource: "a11yToggle")
        }
        .accessibilityAction(named: Text(L10n.t("discover_activity_hide_hint", languageCode: languageCode))) {
            onUserInteracted()
            setState(.hidden, analyticsSource: "a11yHide")
        }
    }

    private var panelAnimation: Animation? {
        reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.30, dampingFraction: 0.90)
    }

    /// One soft green attention pulse (~1.2–1.4s). No loops; decorative (not announced).
    private func runHandleAttentionPulse() {
        handlePulseTask?.cancel()
        handlePulseTask = Task { @MainActor in
            if reduceMotion {
                handleEmphasized = true
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                guard !Task.isCancelled else { return }
                handleEmphasized = false
            } else {
                withAnimation(.easeInOut(duration: 0.35)) {
                    handleEmphasized = true
                }
                try? await Task.sleep(nanoseconds: 650_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.55)) {
                    handleEmphasized = false
                }
            }
        }
    }

    private func resetHandleBreathVisuals() {
        handleBreathScale = 1
        handleBreathOpacity = 0.88
    }

    /// Extremely subtle expand hint: one soft pulse about every 9 seconds while idle.
    private func startHandleBreathingLoop() {
        handleBreathTask?.cancel()
        guard !reduceMotion else {
            resetHandleBreathVisuals()
            return
        }
        handleBreathTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 9_000_000_000)
                guard !Task.isCancelled else { return }
                if isDraggingHandle || handleEmphasized { continue }
                withAnimation(.easeInOut(duration: 0.85)) {
                    handleBreathScale = 1.04
                    handleBreathOpacity = 0.96
                }
                try? await Task.sleep(nanoseconds: 850_000_000)
                guard !Task.isCancelled else { return }
                if isDraggingHandle || handleEmphasized {
                    resetHandleBreathVisuals()
                    continue
                }
                withAnimation(.easeInOut(duration: 0.85)) {
                    resetHandleBreathVisuals()
                }
            }
        }
    }

    private var visibleDragOffset: CGFloat {
        switch state {
        case .expanded:
            return min(max(dragTranslation * 0.12, 0), 18)
        case .compact:
            if dragTranslation > 0 {
                return min(dragTranslation * 0.12, 16)
            }
            return max(dragTranslation * 0.12, -14)
        case .hidden:
            return 0
        }
    }

    private var visibleDragGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .updating($dragTranslation) { value, state, _ in
                state = value.translation.height
            }
            .onEnded { value in
                let dy = value.translation.height
                let predicted = value.predictedEndTranslation.height
                onUserInteracted()
                settleVisibleDrag(dy: dy, predicted: predicted)
            }
    }

    private var hiddenDragGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .onEnded { value in
                let dy = value.translation.height
                let predicted = value.predictedEndTranslation.height
                guard dy < -16 || predicted < -28 else { return }
                onUserInteracted()
                if dy < -72 || predicted < -110 {
                    setState(.expanded, analyticsSource: "dragHidden")
                } else {
                    setState(.compact, analyticsSource: "dragHidden")
                }
            }
    }

    private func settleVisibleDrag(dy: CGFloat, predicted: CGFloat) {
        switch state {
        case .expanded:
            if dy > 28 || predicted > 48 {
                setState(.compact, analyticsSource: "drag")
            }
        case .compact:
            if dy < -28 || predicted < -48 {
                setState(.expanded, analyticsSource: "drag")
            } else if dy > 28 || predicted > 48 {
                setState(.hidden, analyticsSource: "drag")
            }
        case .hidden:
            break
        }
    }

    private func setState(_ next: DiscoverActivityPanelState, analyticsSource: String) {
        guard state != next else { return }
        let previous = state
        withAnimation(panelAnimation) {
            state = next
        }
        FanGeoDiscoverActivityPanelPreferences.persistState(next, for: accountUserId)
        announceStateChange(next)
#if DEBUG
        print("[DiscoverActivityPanelPerf] state=\(debugName(next))")
#endif
        recordStateAnalytics(from: previous, to: next, source: analyticsSource)
    }

    private func announceStateChange(_ next: DiscoverActivityPanelState) {
        let announcement: String
        switch next {
        case .hidden:
            announcement = L10n.t("discover_activity_hidden_a11y", languageCode: languageCode)
        case .compact, .expanded:
            announcement = L10n.t("discover_activity_summary_a11y", languageCode: languageCode)
        }
        AccessibilityNotification.Announcement(announcement).post()
    }

    private func debugName(_ value: DiscoverActivityPanelState) -> String {
        switch value {
        case .hidden: return "hidden"
        case .compact: return "compact"
        case .expanded: return "expanded"
        }
    }

    private func recordStateAnalytics(
        from previous: DiscoverActivityPanelState,
        to next: DiscoverActivityPanelState,
        source: String
    ) {
        let eventName: String
        switch (previous, next) {
        case (_, .hidden):
            eventName = "discover_activity_panel_hidden"
        case (.hidden, .compact), (.hidden, .expanded):
            eventName = "discover_activity_panel_restored"
        case (_, .expanded):
            eventName = "discover_activity_panel_expanded"
        case (.expanded, .compact):
            eventName = "discover_activity_panel_collapsed"
        default:
            eventName = "discover_activity_panel_collapsed"
        }
        FanGeoAnalyticsService.record(
            eventName: eventName,
            sport: nil,
            metadata: ["source": source],
            updateLastActive: false
        )
    }

    private var introInstructionHeightBudget: CGFloat {
        showsExpandedIntroInstruction ? 34 : 0
    }

    private var contextHeaderHeightBudget: CGFloat {
        guard let header = presentation.contextHeader else { return 0 }
        let hasSummary = isExpanded
            && !(header.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        // One-line location title is the common case after duplicate-summary suppression.
        return hasSummary ? 44 : 22
    }

    private var metricSupportingHeightBudget: CGFloat {
        guard isExpanded else { return 0 }
        let hasAny = presentation.metricItems.contains {
            ($0.supportingText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        }
        return hasAny ? 18 : 0
    }

    /// Room for favorite-team and/or next-event insight rows beneath the metric grid.
    private var insightRowsHeightBudget: CGFloat {
        guard isExpanded, !isGuestMode else { return 0 }
        var budget: CGFloat = 0
        if presentation.favoriteTeamInsight != nil {
            budget += 30
        }
        if presentation.timelyInsight != nil {
            // Title + relative + absolute + location (up to 2 lines) + padding + top gap.
            budget += 108
        }
        if budget > 0 {
            budget += 10 // breathing room above the first insight card
        }
        return budget
    }

    private var visiblePanelMinHeight: CGFloat {
        if !isExpanded { return 50 + contextHeaderHeightBudget }
        if showsGuestCTA {
            return 210 + introInstructionHeightBudget + contextHeaderHeightBudget + metricSupportingHeightBudget
        }
        // Metrics-only base; insight cards use ``insightRowsHeightBudget``.
        return 108
            + introInstructionHeightBudget
            + contextHeaderHeightBudget
            + metricSupportingHeightBudget
            + insightRowsHeightBudget
    }

    private var visiblePanelMaxHeight: CGFloat {
        if !isExpanded { return 58 + contextHeaderHeightBudget }
        if showsGuestCTA {
            return 268 + introInstructionHeightBudget + contextHeaderHeightBudget + metricSupportingHeightBudget
        }
        // Extra headroom so Dynamic Type / 2-line address can grow without clipping.
        return 136
            + introInstructionHeightBudget
            + contextHeaderHeightBudget
            + metricSupportingHeightBudget
            + insightRowsHeightBudget
    }

    private func contextHeaderView(
        _ header: DiscoverActivityPanelContextHeader,
        showSummary: Bool
    ) -> some View {
        let summary = header.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let showsSummaryLine = showSummary && !summary.isEmpty

        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FGColor.accentBlue)
                .frame(width: 18, alignment: .center)
                .padding(.top, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(header.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.leading)
                    .lineLimit(showsSummaryLine ? 2 : 1)
                    .minimumScaleFactor(0.88)
                    .fixedSize(horizontal: false, vertical: true)

                if showsSummaryLine {
                    Text(summary)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .multilineTextAlignment(.leading)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            showsSummaryLine
                ? header.accessibilityLabel
                : header.title
        )
    }

    private var compactContent: some View {
        adaptiveMetricRow(items: presentation.metricItems, expanded: false)
    }

    private var expandedContent: some View {
        VStack(spacing: isGuestMode ? 8 : 0) {
            if isGuestMode {
                Text(L10n.t("discover_activity_guest_identity", languageCode: languageCode))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(L10n.t("discover_activity_guest_identity", languageCode: languageCode))
            }

            if showsExpandedIntroInstruction {
                Text(L10n.t("discover_activity_intro_swipe_hint", languageCode: languageCode))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.isStaticText)
                    .padding(.bottom, 4)
            }

            adaptiveMetricRow(items: presentation.metricItems, expanded: true)

            if !isGuestMode {
                if let favorite = presentation.favoriteTeamInsight {
                    DiscoverPersonalizedInsightRow(insight: favorite)
                        .padding(.top, FGSpacing.sm + 2)
                }
                if let timely = presentation.timelyInsight {
                    DiscoverPersonalizedInsightRow(insight: timely) {
                        guard timely.isNextEventTappable else { return }
                        onUserInteracted()
                        onNextEventTap(timely)
                    }
                    .padding(.top, presentation.favoriteTeamInsight != nil ? FGSpacing.sm : FGSpacing.sm + 2)
                }
            }

            if isGuestMode {
                DiscoverActivityGuestCTARow(
                    title: L10n.t("discover_activity_guest_cta_title", languageCode: languageCode),
                    supportingText: L10n.t("discover_activity_guest_cta_supporting", languageCode: languageCode),
                    buttonTitle: L10n.t("discover_guest_cta_button", languageCode: languageCode),
                    onCreateAccount: onGuestCreateAccount
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func adaptiveMetricRow(items: [DiscoverActivityPanelItem], expanded: Bool) -> some View {
        if items.isEmpty {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: expanded ? 8 : 0) {
                ForEach(items) { item in
                    metricLeaf(item: item, expanded: expanded)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private func metricLeaf(item: DiscoverActivityPanelItem, expanded: Bool) -> some View {
        let card = Group {
            if expanded {
                expandedCard(item: item)
            } else {
                compactStat(item: item)
            }
        }
        if item.isTappable {
            Button {
                onUserInteracted()
                if isGuestMode {
                    onGuestCreateAccount()
                } else {
                    onMetricTap(item.kind)
                }
            } label: {
                card
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .top)
            .accessibilityHint(metricAccessibilityHint(for: item))
        } else {
            card
                .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private func metricAccessibilityHint(for item: DiscoverActivityPanelItem) -> String {
        if isGuestMode {
            return L10n.t("discover_activity_create_account_hint", languageCode: languageCode)
        }
        switch item.kind {
        case .fansNearby:
            return L10n.t("discover_activity_fans_nearby_opens_chat_hint", languageCode: languageCode)
        default:
            return L10n.t("discover_activity_open_destination_hint", languageCode: languageCode)
        }
    }

    private func tint(for kind: DiscoverActivityPanelItem.Kind) -> Color {
        switch kind {
        case .fansNearby: return FGColor.accentGreen
        case .venuePlansToday: return FGColor.accentBlue
        case .pickupPlansToday: return FGColor.accentBlue
        case .suggestedFans: return FGColor.accentGreen
        case .pickupSoon: return FGColor.accentBlue
        case .favoriteTeam: return FGColor.accentYellow
        }
    }

    private func compactStat(item: DiscoverActivityPanelItem) -> some View {
        HStack(alignment: .center, spacing: 5) {
            Image(systemName: item.systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint(for: item.kind))
                .frame(
                    width: DiscoverActivityPanelMetricLayout.compactIconSide,
                    height: DiscoverActivityPanelMetricLayout.compactIconSide,
                    alignment: .center
                )
                .accessibilityHidden(true)
            Text(item.valueText)
                .font(FGTypography.caption.weight(.heavy))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .modifier(OptionalMonospacedDigit(enabled: item.valueUsesMonospacedDigits))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: DiscoverActivityPanelMetricLayout.compactValueHeight, alignment: .center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabel)
    }

    private func expandedCard(item: DiscoverActivityPanelItem) -> some View {
        let supporting = item.supportingText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasSupporting = !supporting.isEmpty

        return VStack(spacing: DiscoverActivityPanelMetricLayout.expandedStackSpacing) {
            Image(systemName: item.systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint(for: item.kind))
                .frame(
                    width: DiscoverActivityPanelMetricLayout.expandedIconSide,
                    height: DiscoverActivityPanelMetricLayout.expandedIconSide,
                    alignment: .center
                )
                .accessibilityHidden(true)

            Text(item.valueText)
                .font(.system(
                    size: item.valueUsesMonospacedDigits
                        ? DiscoverActivityPanelMetricLayout.expandedValueFont
                        : DiscoverActivityPanelMetricLayout.expandedValueFontUnavailable,
                    weight: .heavy,
                    design: .rounded
                ))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .modifier(OptionalMonospacedDigit(enabled: item.valueUsesMonospacedDigits))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .frame(height: DiscoverActivityPanelMetricLayout.expandedValueHeight, alignment: .center)

            Text(item.labelText)
                .font(FGTypography.metadata.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .top)
                .frame(height: DiscoverActivityPanelMetricLayout.expandedTitleHeight, alignment: .top)

            if hasSupporting {
                Text(supporting)
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabel)
    }

    private var compactAccessibilityLabel: String {
        var parts = [L10n.t("discover_activity_summary_a11y", languageCode: languageCode)]
        if let header = presentation.contextHeader {
            parts.append(header.title)
        }
        parts.append(contentsOf: presentation.metricItems.map(\.accessibilityLabel))
        return parts.joined(separator: ". ")
    }
}

/// Shared metric column geometry — keeps all four cards on identical baselines.
private enum DiscoverActivityPanelMetricLayout {
    static let compactIconSide: CGFloat = 14
    static let compactValueHeight: CGFloat = 16

    static let expandedStackSpacing: CGFloat = 3
    static let expandedIconSide: CGFloat = 16
    static let expandedValueFont: CGFloat = 23
    static let expandedValueFontUnavailable: CGFloat = 18
    /// Shared value slot (fits count / em dash / short guest CTA on up to 2 lines).
    static let expandedValueHeight: CGFloat = 34
    /// Two-line metadata title slot.
    static let expandedTitleHeight: CGFloat = 28
}

private struct OptionalMonospacedDigit: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.monospacedDigit()
        } else {
            content
        }
    }
}
