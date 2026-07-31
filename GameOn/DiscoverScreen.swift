import Combine
import CoreLocation
import SwiftUI
import MapKit
import UIKit
enum VenueGameCardDiagnostics {
    static let enabled = false
}

private enum GuestDiscoverLockedCopy {
    static let body =
        "Log in or create a FanGeo account to view details, join pickup games, save venues, and unlock the full FanGeo experience."
}

private enum DiscoverPreviewDateFormatters {
    static let sqlDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let sqlDayWithShortTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd h:mm a"
        formatter.timeZone = TimeZone.current
        return formatter
    }()
}

#if DEBUG
@MainActor
private enum VenueHeroCrashDebugTracker {
    private static var appearances: [String: (count: Int, firstSeen: Date)] = [:]

    static func recordAppearance(renderKey: String) {
        let now = Date()
        let existing = appearances[renderKey]
        let firstSeen = existing?.firstSeen ?? now
        let elapsed = now.timeIntervalSince(firstSeen)
        let count = elapsed > 2 ? 1 : (existing?.count ?? 0) + 1
        appearances[renderKey] = (count, elapsed > 2 ? now : firstSeen)

        if count >= 4 {
            print("[VenueHeroCrashDebug] duplicateRenderStorm renderKey=\(renderKey) count=\(count)")
        }
    }
}
#endif

private struct DiscoverPredictionSheetContext: Identifiable {
    let venueEventID: UUID
    let teams: VenueEventPredictionTeams
    let predictionType: VenueEventPredictionType
    let unavailableMessage: String?
    let lockTime: Date?

    var id: String {
        "\(venueEventID.uuidString.lowercased())|\(predictionType.rawValue)"
    }
}

enum FanGeoStartupGuidePreferences {
    static let hideAtStartupKey = "hideStartupGuide"
    private static let legacyHideAtStartupKey = "fanGeoHideStartupGuide"

    private static func accountScopedKey(for userId: UUID) -> String {
        "\(hideAtStartupKey).\(userId.uuidString.lowercased())"
    }

    /// `true` = hide startup guide. Missing account-scoped keys default to `false` (checkbox unchecked).
    static func shouldHideAtStartup(for userId: UUID?) -> Bool {
        let defaults = UserDefaults.standard
        if let userId {
            let key = accountScopedKey(for: userId)
            if defaults.object(forKey: key) != nil {
                return defaults.bool(forKey: key)
            }
            // New / never-configured account: unchecked. Do not inherit another account's or the legacy global preference here.
            return false
        }
        return legacyGlobalShouldHideAtStartup(defaults: defaults)
    }

    /// Persists only when the user explicitly toggles the checkbox.
    static func setShouldHideAtStartup(_ value: Bool, for userId: UUID?) {
        let defaults = UserDefaults.standard
        if let userId {
            defaults.set(value, forKey: accountScopedKey(for: userId))
            return
        }
        defaults.set(value, forKey: hideAtStartupKey)
    }

    /// Brand-new FanGeo accounts must start unchecked and must not inherit the previous device user's preference.
    static func ensureNewAccountDefaultUnchecked(for userId: UUID) {
        let defaults = UserDefaults.standard
        let key = accountScopedKey(for: userId)
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(false, forKey: key)
#if DEBUG
        print("[StartupGuidePref] newAccountDefaultUnchecked userId=\(userId.uuidString.lowercased())")
#endif
    }

    /// One-time migration for returning users who only have the pre–account-scoped global key.
    /// Never call this for newly created accounts (those use ``ensureNewAccountDefaultUnchecked(for:)`` first).
    static func migrateLegacyGlobalPreferenceIfNeeded(for userId: UUID) {
        let defaults = UserDefaults.standard
        let key = accountScopedKey(for: userId)
        guard defaults.object(forKey: key) == nil else { return }
        let hasExplicitGlobal = defaults.object(forKey: hideAtStartupKey) != nil
            || defaults.object(forKey: legacyHideAtStartupKey) != nil
        guard hasExplicitGlobal else { return }
        let value = legacyGlobalShouldHideAtStartup(defaults: defaults)
        defaults.set(value, forKey: key)
#if DEBUG
        print("[StartupGuidePref] migratedLegacyGlobal value=\(value) userId=\(userId.uuidString.lowercased())")
#endif
    }

    private static func legacyGlobalShouldHideAtStartup(defaults: UserDefaults) -> Bool {
        if defaults.object(forKey: hideAtStartupKey) != nil {
            return defaults.bool(forKey: hideAtStartupKey)
        }
        let legacyValue = defaults.bool(forKey: legacyHideAtStartupKey)
        if legacyValue {
            defaults.set(true, forKey: hideAtStartupKey)
        }
        return legacyValue
    }

    static var shouldHideAtStartup: Bool {
        shouldHideAtStartup(for: nil)
    }
}

/// Validates saved FanGeo profile display names for Welcome guide personalization.
enum FanGeoWelcomeDisplayName {
    static func sanitized(_ raw: String?) -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        let placeholders: Set<String> = [
            "fan",
            "fan geo",
            "fangeo",
            "fangeo fan",
            "user",
            "guest",
            "anonymous",
            "new user",
            "display name",
            "your name"
        ]
        if placeholders.contains(lowered) { return nil }
        if trimmed.hasPrefix("@") { return nil }
        if trimmed.contains("@") { return nil }
        if lowered.contains("privaterelay.appleid.com") { return nil }
        if lowered.hasPrefix("user") && trimmed.contains(where: { $0.isNumber }) && trimmed.count <= 12 {
            // Avoid generic "user123" style placeholders without rejecting real names.
            return nil
        }
        return trimmed
    }
}

private enum DiscoverSearchSuggestionSource: String, Codable, Sendable {
    case city
    case place
    case recent
    case game
    case team
    case sport
    case league
    case venue
    case fan
    case proGame
}

private enum DiscoverRecentSearchKind: String, Codable, Sendable {
    case city
    case venue
    case pickupPlace
    case team
    case game
    case sport
    case league
    case fan
    case proGame

    var iconSystemName: String {
        switch self {
        case .city: return "mappin.circle.fill"
        case .venue: return "building.2.fill"
        case .pickupPlace: return "figure.soccer"
        case .team: return "shield.fill"
        case .game: return "sportscourt.fill"
        case .sport: return "figure.run"
        case .league: return "trophy.fill"
        case .fan: return "person.crop.circle.fill"
        case .proGame: return "sportscourt.fill"
        }
    }
}

private struct DiscoverSearchSuggestion: Identifiable, Hashable, Codable, Sendable {
    let title: String
    let subtitle: String
    let latitude: Double?
    let longitude: Double?
    let source: DiscoverSearchSuggestionSource
    let kind: DiscoverRecentSearchKind?
    /// Venue IDs for game/league selections (not persisted in recent searches).
    let venueIDs: [UUID]?
    let sportToken: String?
    let leagueToken: String?
    let accessibilityLabelOverride: String?
    let fanUserId: UUID?
    let fanAvatarURL: String?
    let fanIsFriend: Bool?
    let proGameStableKey: String?

    nonisolated init(
        title: String,
        subtitle: String,
        latitude: Double?,
        longitude: Double?,
        source: DiscoverSearchSuggestionSource,
        kind: DiscoverRecentSearchKind?,
        venueIDs: [UUID]? = nil,
        sportToken: String? = nil,
        leagueToken: String? = nil,
        accessibilityLabelOverride: String? = nil,
        fanUserId: UUID? = nil,
        fanAvatarURL: String? = nil,
        fanIsFriend: Bool? = nil,
        proGameStableKey: String? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.latitude = latitude
        self.longitude = longitude
        self.source = source
        self.kind = kind
        self.venueIDs = venueIDs
        self.sportToken = sportToken
        self.leagueToken = leagueToken
        self.accessibilityLabelOverride = accessibilityLabelOverride
        self.fanUserId = fanUserId
        self.fanAvatarURL = fanAvatarURL
        self.fanIsFriend = fanIsFriend
        self.proGameStableKey = proGameStableKey
    }

    var id: String {
        [
            source.rawValue,
            Self.normalizedText(title),
            Self.normalizedText(subtitle),
            sportToken.map(Self.normalizedText) ?? "",
            leagueToken.map(Self.normalizedText) ?? "",
            (venueIDs ?? []).map(\.uuidString).sorted().joined(separator: ","),
            fanUserId?.uuidString.lowercased() ?? "",
            proGameStableKey ?? ""
        ].joined(separator: "|")
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var displayQuery: String {
        switch source {
        case .game, .sport, .league, .team, .venue, .proGame:
            return title.trimmingCharacters(in: .whitespacesAndNewlines)
        case .fan:
            let handle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if handle.hasPrefix("@"), handle.count > 1 { return handle }
            return title.trimmingCharacters(in: .whitespacesAndNewlines)
        case .city, .place, .recent:
            break
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSubtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSubtitle.isEmpty else { return cleanTitle }
        guard !cleanTitle.localizedCaseInsensitiveContains(cleanSubtitle) else { return cleanTitle }
        return "\(cleanTitle), \(cleanSubtitle)"
    }

    var displayKind: DiscoverRecentSearchKind {
        kind ?? Self.inferredKind(for: self)
    }

    nonisolated static func normalizedText(_ raw: String) -> String {
        DiscoverVenueEventSearch.normalize(raw)
    }

    static func inferredKind(forSearchText text: String) -> DiscoverRecentSearchKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .city }
        if !FavoriteTeamCatalog.searchTeams(trimmed).isEmpty {
            return .team
        }
        return .city
    }

    static func inferredKind(for suggestion: DiscoverSearchSuggestion) -> DiscoverRecentSearchKind {
        switch suggestion.source {
        case .city, .place:
            return .city
        case .game:
            return .game
        case .team:
            return .team
        case .sport:
            return .sport
        case .league:
            return .league
        case .venue:
            return .venue
        case .fan:
            return .fan
        case .proGame:
            return .proGame
        case .recent:
            return suggestion.kind ?? inferredKind(forSearchText: suggestion.displayQuery)
        }
    }

    nonisolated static func fromVenueEventSuggestion(_ suggestion: DiscoverVenueEventSearch.Suggestion) -> DiscoverSearchSuggestion {
        let source: DiscoverSearchSuggestionSource
        let kind: DiscoverRecentSearchKind
        switch suggestion.kind {
        case .game:
            source = .game
            kind = .game
        case .team:
            source = .team
            kind = .team
        case .sport:
            source = .sport
            kind = .sport
        case .league:
            source = .league
            kind = .league
        }
        return DiscoverSearchSuggestion(
            title: suggestion.title,
            subtitle: suggestion.subtitle,
            latitude: nil,
            longitude: nil,
            source: source,
            kind: kind,
            venueIDs: suggestion.venueIDs,
            sportToken: suggestion.sportToken,
            leagueToken: suggestion.leagueToken,
            accessibilityLabelOverride: suggestion.accessibilityLabel
        )
    }

    static func fromVenueBar(_ bar: BarVenue, languageCode: String) -> DiscoverSearchSuggestion {
        DiscoverSearchSuggestion(
            title: bar.name,
            subtitle: bar.address,
            latitude: bar.coordinate.latitude,
            longitude: bar.coordinate.longitude,
            source: .venue,
            kind: .venue,
            venueIDs: [bar.id],
            accessibilityLabelOverride: [
                bar.name,
                L10n.t("discover_search_kind_venue", languageCode: languageCode)
            ].joined(separator: ". ")
        )
    }

    static func fromFan(_ fan: DiscoverFanSearchResult, languageCode: String) -> DiscoverSearchSuggestion {
        let handle = fan.displayHandle
        let handleLine = handle.isEmpty ? "" : handle
        let friendSuffix = fan.is_friend
            ? L10n.t("discover_search_fan_friends_label", languageCode: languageCode)
            : ""
        let subtitleParts = [handleLine, friendSuffix].filter { !$0.isEmpty }
        let a11yHandle = handle.isEmpty
            ? ""
            : String(
                format: L10n.t("discover_search_fan_a11y_handle_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
            )
        var a11yParts = [
            fan.display_name,
            a11yHandle,
            L10n.t("discover_search_kind_fan", languageCode: languageCode)
        ].filter { !$0.isEmpty }
        if fan.is_friend {
            a11yParts.append(L10n.t("discover_search_fan_friends_label", languageCode: languageCode))
        }
        return DiscoverSearchSuggestion(
            title: fan.display_name,
            subtitle: subtitleParts.joined(separator: " · "),
            latitude: nil,
            longitude: nil,
            source: .fan,
            kind: .fan,
            accessibilityLabelOverride: a11yParts.joined(separator: ", "),
            fanUserId: fan.user_id,
            fanAvatarURL: fan.avatar_url,
            fanIsFriend: fan.is_friend
        )
    }

    static func fromProGame(_ match: LiveMatch, languageCode: String) -> DiscoverSearchSuggestion {
        let locale = Locale(identifier: languageCode)
        let isLive = match.matchStatus.isHappeningNow
        let isFinal = match.matchStatus == .fullTime
        let title: String
        if isLive, match.scoresAreAvailable {
            title = "\(match.homeTeam) \(match.scoreHome)–\(match.scoreAway) \(match.awayTeam)"
        } else {
            title = "\(match.homeTeam) vs \(match.awayTeam)"
        }

        var subtitleParts: [String] = []
        if isLive {
            subtitleParts.append(L10n.t("LIVE", languageCode: languageCode))
            if let clock = match.liveClockText?.trimmingCharacters(in: .whitespacesAndNewlines), !clock.isEmpty {
                subtitleParts.append(clock)
            } else if let minute = match.minute {
                subtitleParts.append("\(minute)′")
            }
        } else if isFinal {
            subtitleParts.append(L10n.t("Final", languageCode: languageCode))
        } else {
            subtitleParts.append(Self.proGameRelativeDayLabel(for: match.startTime, languageCode: languageCode))
            subtitleParts.append(Self.proGameTimeFormatter(locale: locale).string(from: match.startTime))
        }

        let league = match.league.trimmingCharacters(in: .whitespacesAndNewlines)
        if !league.isEmpty, isLive || isFinal {
            subtitleParts.append(league)
        }

        let a11yStatus: String
        if isLive, match.scoresAreAvailable {
            a11yStatus = "\(match.scoreHome) to \(match.scoreAway), \(L10n.t("LIVE", languageCode: languageCode))"
        } else if isLive {
            a11yStatus = L10n.t("LIVE", languageCode: languageCode)
        } else if isFinal {
            a11yStatus = L10n.t("Final", languageCode: languageCode)
        } else {
            a11yStatus = Self.proGameAccessibilityDateFormatter(locale: locale).string(from: match.startTime)
        }

        return DiscoverSearchSuggestion(
            title: title,
            subtitle: subtitleParts.joined(separator: " · "),
            latitude: match.venueLatitude,
            longitude: match.venueLongitude,
            source: .proGame,
            kind: .proGame,
            accessibilityLabelOverride: [
                "\(match.homeTeam) vs \(match.awayTeam)",
                a11yStatus,
                league,
                L10n.t("discover_search_kind_pro_game", languageCode: languageCode)
            ].filter { !$0.isEmpty }.joined(separator: ", "),
            proGameStableKey: SavedProGame.stableKey(for: match)
        )
    }

    /// Concise local-day label for scheduled pro games (`Today` / `Tomorrow` / short date).
    private static func proGameRelativeDayLabel(for date: Date, languageCode: String) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return L10n.t("Today", languageCode: languageCode)
        }
        if calendar.isDateInTomorrow(date) {
            return L10n.t("Tomorrow", languageCode: languageCode)
        }
        return Self.proGameDateFormatter(locale: Locale(identifier: languageCode)).string(from: date)
    }

    private static var proGameDateFormatters: [String: DateFormatter] = [:]
    private static var proGameTimeFormatters: [String: DateFormatter] = [:]
    private static var proGameA11yDateFormatters: [String: DateFormatter] = [:]

    private static func proGameDateFormatter(locale: Locale) -> DateFormatter {
        let key = locale.identifier
        if let existing = proGameDateFormatters[key] { return existing }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        proGameDateFormatters[key] = formatter
        return formatter
    }

    private static func proGameTimeFormatter(locale: Locale) -> DateFormatter {
        let key = locale.identifier
        if let existing = proGameTimeFormatters[key] { return existing }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        proGameTimeFormatters[key] = formatter
        return formatter
    }

    private static func proGameAccessibilityDateFormatter(locale: Locale) -> DateFormatter {
        let key = locale.identifier
        if let existing = proGameA11yDateFormatters[key] { return existing }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        proGameA11yDateFormatters[key] = formatter
        return formatter
    }
}

private enum DiscoverRecentSearchStore {
    private static let storageKey = "fangeo.discover.recentSearches"
    private static let maxCount = 5

    static func load() -> [DiscoverSearchSuggestion] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([DiscoverSearchSuggestion].self, from: data) else {
            return []
        }
        return Array(decoded.prefix(maxCount)).map {
            DiscoverSearchSuggestion(
                title: $0.title,
                subtitle: $0.subtitle,
                latitude: $0.latitude,
                longitude: $0.longitude,
                source: .recent,
                kind: $0.kind,
                fanUserId: $0.fanUserId,
                fanAvatarURL: $0.fanAvatarURL,
                fanIsFriend: $0.fanIsFriend,
                proGameStableKey: $0.proGameStableKey
            )
        }
    }

    @discardableResult
    static func save(_ suggestion: DiscoverSearchSuggestion, into existing: [DiscoverSearchSuggestion]) -> [DiscoverSearchSuggestion] {
        let title = suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return existing }

        let recent = DiscoverSearchSuggestion(
            title: title,
            subtitle: suggestion.subtitle.trimmingCharacters(in: .whitespacesAndNewlines),
            latitude: suggestion.latitude,
            longitude: suggestion.longitude,
            source: .recent,
            kind: suggestion.kind ?? DiscoverSearchSuggestion.inferredKind(for: suggestion),
            fanUserId: suggestion.fanUserId,
            fanAvatarURL: suggestion.fanAvatarURL,
            fanIsFriend: suggestion.fanIsFriend,
            proGameStableKey: suggestion.proGameStableKey
        )
        let key = DiscoverSearchSuggestion.normalizedText(recent.displayQuery)
        let deduped = existing.filter {
            DiscoverSearchSuggestion.normalizedText($0.displayQuery) != key
        }
        let next = Array(([recent] + deduped).prefix(maxCount))
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        return next
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

@MainActor
private final class DiscoverSearchSuggestionController: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published private(set) var suggestions: [DiscoverSearchSuggestion] = []
    @Published private(set) var recentSearches: [DiscoverSearchSuggestion] = DiscoverRecentSearchStore.load()
    @Published private(set) var isLoading = false

    private let completer = MKLocalSearchCompleter()
    private var debounceTask: Task<Void, Never>?
    private var suggestionCache: [String: [DiscoverSearchSuggestion]] = [:]
    private var activeQueryKey = ""
    private var wantsSuggestions = false

    private static let minimumQueryLength = 2
    private static let suggestionLimit = 5
    private static let debounceMilliseconds: UInt64 = 350

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address]
    }

    func refresh(query: String, isFocused: Bool, region: MKCoordinateRegion?) {
        debounceTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = DiscoverSearchSuggestion.normalizedText(trimmed)
        wantsSuggestions = isFocused && key.count >= Self.minimumQueryLength

        guard isFocused else {
            activeQueryKey = ""
            suggestions = []
            isLoading = false
            return
        }

        guard key.count >= Self.minimumQueryLength else {
            activeQueryKey = ""
            suggestions = []
            isLoading = false
            return
        }

        if let cached = suggestionCache[key] {
            activeQueryKey = key
            suggestions = cached
            isLoading = false
            return
        }

        activeQueryKey = key
        suggestions = []
        isLoading = true

        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceMilliseconds * 1_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.activeQueryKey == key, self.wantsSuggestions else { return }
            if let region {
                self.completer.region = region
            }
            self.completer.queryFragment = trimmed
        }
    }

    func clearSuggestions() {
        debounceTask?.cancel()
        activeQueryKey = ""
        wantsSuggestions = false
        suggestions = []
        isLoading = false
    }

    func remember(_ suggestion: DiscoverSearchSuggestion) {
        recentSearches = DiscoverRecentSearchStore.save(suggestion, into: recentSearches)
    }

    func clearRecentSearches() {
        DiscoverRecentSearchStore.clear()
        recentSearches = []
    }

    func rememberSearchText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        remember(
            DiscoverSearchSuggestion(
                title: trimmed,
                subtitle: "",
                latitude: nil,
                longitude: nil,
                source: .recent,
                kind: DiscoverSearchSuggestion.inferredKind(forSearchText: trimmed)
            )
        )
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let key = DiscoverSearchSuggestion.normalizedText(completer.queryFragment)
            guard self.wantsSuggestions, key == self.activeQueryKey else { return }

            var seen = Set<String>()
            let mapped = completer.results.compactMap { completion -> DiscoverSearchSuggestion? in
                let title = completion.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                let subtitle = completion.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalized = DiscoverSearchSuggestion.normalizedText("\(title), \(subtitle)")
                guard seen.insert(normalized).inserted else { return nil }

                let mappedSource = Self.suggestionSource(title: title, subtitle: subtitle)
                return DiscoverSearchSuggestion(
                    title: title,
                    subtitle: subtitle,
                    latitude: nil,
                    longitude: nil,
                    source: mappedSource,
                    kind: mappedSource == .city ? .city : .city
                )
            }
            .prefix(Self.suggestionLimit)

            let next = Array(mapped)
            self.suggestionCache[key] = next
            self.suggestions = next
            self.isLoading = false
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let key = DiscoverSearchSuggestion.normalizedText(completer.queryFragment)
            guard key == self.activeQueryKey else { return }
            self.suggestions = []
            self.isLoading = false
#if DEBUG
            print("[DiscoverSearchSuggestions] autocompleteFailed query=\(completer.queryFragment) error=\(error.localizedDescription)")
#endif
        }
    }

    private static func suggestionSource(title: String, subtitle: String) -> DiscoverSearchSuggestionSource {
        let subtitleLower = subtitle.lowercased()
        let cityLikeSubtitleTokens = [
            "united states", "usa", "france", "spain", "mexico", "canada", "brazil",
            "united kingdom", "england", "germany", "italy", "portugal", "japan"
        ]
        if cityLikeSubtitleTokens.contains(where: { subtitleLower.contains($0) }) {
            return .city
        }
        return .place
    }
}

private enum PickupGameMapMarkerActivity: Equatable {
    case low
    case medium
    case high

    var glowOpacity: Double {
        switch self {
        case .low: return 0.18
        case .medium: return 0.30
        case .high: return 0.42
        }
    }

    var pulseOpacity: Double {
        switch self {
        case .low: return 0
        case .medium: return 0.22
        case .high: return 0.34
        }
    }
}

private struct MapSportChipIconGlyph: View {
    let sport: String
    let emojiSize: CGFloat
    let symbolSize: CGFloat
    let frameSize: CGFloat
    var fallbackColor: Color = Color.white.opacity(0.94)

    private var visual: SportFilterCatalog.ChipVisual {
        SportFilterCatalog.resolve(sport)
    }

    private var usesEmoji: Bool {
        !visual.emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isNeutralFallback: Bool {
        !usesEmoji && visual.systemImage == "sportscourt.fill"
    }

    var body: some View {
        Group {
            if usesEmoji {
                Text(visual.emoji)
                    .font(.system(size: emojiSize))
                    .baselineOffset(-emojiSize * 0.03)
                    .minimumScaleFactor(0.82)
                    .lineLimit(1)
            } else {
                Image(systemName: visual.systemImage)
                    .font(.system(size: symbolSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(isNeutralFallback ? fallbackColor : visual.accent)
            }
        }
        .frame(width: frameSize, height: frameSize)
        .accessibilityHidden(true)
    }
}

private struct PickupGameMapMarker: View {
    let sport: String
    let accentColor: Color
    let markerType: String
    let reusedSportChipIcon: Bool
    let activity: PickupGameMapMarkerActivity
    var demandBadgeText: String?
    var isSelected = false
    var isCluster = false
    var allowsPulse = true
    var count: Int?

    @Environment(\.colorScheme) private var colorScheme
    @State private var pulse = false
    @State private var demandBadgeVisible = false

    private var baseSize: CGFloat { isCluster ? 44 : 48 }
    private var glyphSize: CGFloat { isCluster ? 23 : 27 }
    private var scale: CGFloat {
        if isSelected { return 1.20 }
        return isCluster ? 0.94 : 1.0
    }

    private var markerFill: Color {
        colorScheme == .dark ? Color(red: 0.03, green: 0.06, blue: 0.09) : Color(red: 0.02, green: 0.05, blue: 0.08)
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.92) : Color.white
    }

    var body: some View {
        let shouldPulse = allowsPulse && activity != .low
        ZStack {
            Circle()
                .stroke(accentColor.opacity(activity.pulseOpacity), lineWidth: activity == .high ? 3 : 2)
                .frame(width: baseSize + 18, height: baseSize + 18)
                .scaleEffect(shouldPulse && pulse ? 1.22 : 0.98)
                .opacity(activity.pulseOpacity)
                .animation(
                    shouldPulse
                        ? .easeInOut(duration: activity == .high ? 1.05 : 1.35).repeatForever(autoreverses: true)
                        : nil,
                    value: pulse
                )

            Circle()
                .fill(accentColor.opacity(activity.glowOpacity))
                .frame(width: baseSize + 14, height: baseSize + 14)
                .blur(radius: 5)

            Circle()
                .fill(markerFill)
                .frame(width: baseSize, height: baseSize)
                .overlay {
                    Circle()
                        .strokeBorder(borderColor, lineWidth: isSelected ? 3 : 2.25)
                }
                .overlay {
                    Circle()
                        .strokeBorder(accentColor.opacity(0.78), lineWidth: isSelected ? 2 : 1.5)
                        .padding(isSelected ? 4 : 4.5)
                }
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.34 : 0.24), radius: isSelected ? 10 : 7, y: isSelected ? 6 : 4)

            Circle()
                .fill((reusedSportChipIcon ? accentColor : Color.white).opacity(reusedSportChipIcon ? 0.18 : 0.10))
                .frame(width: baseSize * 0.68, height: baseSize * 0.68)

            MapSportChipIconGlyph(
                sport: sport,
                emojiSize: glyphSize,
                symbolSize: glyphSize * 0.78,
                frameSize: baseSize * 0.70
            )

            if let count, isCluster {
                Text("\(count)")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(accentColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.white)
                    .clipShape(Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.75)
                    }
                    .offset(x: 15, y: 15)
            }

            if let demandBadgeText, !isCluster {
                Text(demandBadgeText)
                    .font(.system(size: demandBadgeText == "FULL" ? 8 : 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(demandBadgeText == "FULL" ? Color.white : markerFill)
                    .padding(.horizontal, demandBadgeText == "FULL" ? 6 : 5)
                    .frame(minWidth: demandBadgeText == "FULL" ? 34 : 22, minHeight: 22)
                    .background {
                        Capsule(style: .continuous)
                            .fill(demandBadgeText == "FULL" ? Color.black.opacity(0.86) : Color.white)
                    }
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(accentColor.opacity(0.45), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
                    .scaleEffect(demandBadgeVisible ? 1.0 : 0.9)
                    .opacity(demandBadgeVisible ? 1 : 0)
                    .animation(.spring(response: 0.22, dampingFraction: 0.78), value: demandBadgeVisible)
                    .offset(x: 18, y: -18)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: baseSize + 24, height: baseSize + 24)
        .scaleEffect(scale)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isSelected)
        .onAppear {
            pulse = shouldPulse
            demandBadgeVisible = demandBadgeText != nil && !isCluster
#if DEBUG
            print("[MapSportIconDebug] reusedSportChipIcon=\(reusedSportChipIcon)")
            print("[MapSportIconDebug] sport=\(sport)")
            print("[MapSportIconDebug] markerType=\(markerType)")
#endif
        }
        .onChange(of: activity) { _, next in
            pulse = allowsPulse && next != .low
        }
        .onChange(of: demandBadgeText) { _, next in
            demandBadgeVisible = next != nil && !isCluster
        }
    }
}

private struct PickupPlaceClusterSheetView: View {
    let cluster: PickupPlaceCluster
    let currentUserLocation: CLLocationCoordinate2D?
    let onHostGameHere: (PickupPlaceRow) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    private var title: String {
        "\(cluster.count) pickup \(cluster.count == 1 ? "place" : "places")"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(cluster.rows) { place in
                        pickupPlaceClusterRow(place)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(FGTypography.metadata.weight(.semibold))
                }
            }
        }
    }

    private func pickupPlaceClusterRow(_ place: PickupPlaceRow) -> some View {
        let sport = place.primarySport
        let type = place.placeType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let location = pickupPlaceClusterLocationText(place)
        let distance = pickupPlaceClusterDistanceText(place)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: pickupPlaceClusterSportSymbol(for: place))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.accentBlue)
                    .frame(width: 38, height: 38)
                    .background(
                        Circle()
                            .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.18 : 0.10))
                    )

                VStack(alignment: .leading, spacing: 5) {
                    Text(place.name)
                        .font(FGTypography.body.weight(.heavy))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)

                    Text([sport, type].filter { !$0.isEmpty }.joined(separator: " • "))
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(2)

                    if !location.isEmpty {
                        Label(location, systemImage: "mappin.circle.fill")
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(2)
                    }

                    if let distance {
                        Label(distance, systemImage: "location.fill")
                            .font(FGTypography.caption.weight(.semibold))
                            .foregroundStyle(FGColor.accentGreen)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                onHostGameHere(place)
            } label: {
                Text("Host game here")
                    .font(FGTypography.metadata.weight(.heavy))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(FGColor.accentBlue)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.42), lineWidth: 1)
        }
    }

    private func pickupPlaceClusterLocationText(_ place: PickupPlaceRow) -> String {
        [place.city, place.state, place.zip]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private func pickupPlaceClusterDistanceText(_ place: PickupPlaceRow) -> String? {
        guard let currentUserLocation else { return nil }
        let origin = CLLocation(latitude: currentUserLocation.latitude, longitude: currentUserLocation.longitude)
        let destination = CLLocation(latitude: place.latitude, longitude: place.longitude)
        let miles = origin.distance(from: destination) / 1609.344
        guard miles.isFinite else { return nil }
        if miles < 0.1 {
            return "Nearby"
        }
        return String(format: "%.1f mi away", miles)
    }

    private func pickupPlaceClusterSportSymbol(for place: PickupPlaceRow) -> String {
        let text = ([place.primarySport, place.placeType ?? ""] + place.sportTags)
            .joined(separator: " ")
            .lowercased()
        if text.contains("soccer") { return "soccerball" }
        if text.contains("basketball") { return "basketball.fill" }
        if text.contains("baseball") || text.contains("softball") { return "baseball.fill" }
        if text.contains("tennis") || text.contains("pickleball") || text.contains("badminton") || text.contains("padel") { return "figure.tennis" }
        if text.contains("paragliding") || text.contains("hang_gliding") || text.contains("hang gliding") || text.contains("paramotoring") { return "wind" }
        if text.contains("volleyball") { return "volleyball.fill" }
        if text.contains("dance") || text.contains("breakdance") || text.contains("breaking") || text.contains("ballet") { return "figure.dance" }
        return "sportscourt.fill"
    }
}

private struct MapDepthPulseRing: View {
    let tint: Color
    @State private var pulse = false

    var body: some View {
        Circle()
            .stroke(tint.opacity(pulse ? 0.10 : 0.22), lineWidth: 2)
            .scaleEffect(pulse ? 1.34 : 1.02)
            .opacity(pulse ? 0.16 : 0.30)
            .animation(.easeInOut(duration: 1.55).repeatForever(autoreverses: true), value: pulse)
            .allowsHitTesting(false)
            .onAppear {
                pulse = true
            }
    }
}

private struct FanChatActivityPulse: View {
    let tint: Color
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(isActive ? 0.22 : 0), lineWidth: 2)
                .frame(width: 18, height: 18)
                .scaleEffect(pulse && !reduceMotion ? 1.28 : 0.92)
                .opacity(isActive ? 1 : 0)
                .animation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true), value: pulse)

            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
                .shadow(color: tint.opacity(isActive ? 0.45 : 0.18), radius: isActive ? 5 : 2, y: 0)
        }
        .frame(width: 20, height: 20)
        .onAppear {
            pulse = isActive
        }
        .onChange(of: isActive) { _, next in
            pulse = next
        }
    }
}

private struct FanChatMiniActivityStack: View {
    let tint: Color
    let isHot: Bool

    private var colors: [Color] {
        isHot ? [FGColor.dangerRed, FGColor.accentYellow, FGColor.accentBlue] : [tint, FGColor.accentGreen, FGColor.accentYellow]
    }

    var body: some View {
        HStack(spacing: -5) {
            ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                Circle()
                    .fill(color.opacity(index == 0 ? 0.95 : 0.78))
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.88), lineWidth: 1.4))
                    .shadow(color: color.opacity(0.18), radius: 3, y: 1)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Guest-only conversion leaf for venue game cards. Signed-in Going/Chat/Predictions stay in the parent card.
private struct GuestGameInteractionSection: View {
    let languageCode: String
    let onCreateAccount: () -> Void
    let onSignIn: () -> Void
    /// When true, text styles suit the dark hero footer chrome.
    var usesDarkHeroChrome: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "star.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FGColor.accentYellow)
                    .accessibilityHidden(true)

                Text(L10n.t("discover_guest_cta_title", languageCode: languageCode))
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(
                        usesDarkHeroChrome
                            ? Color.white.opacity(0.78)
                            : FGColor.secondaryText(colorScheme)
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: 8) {
                FGPrimaryButton(
                    title: L10n.t("discover_guest_cta_button", languageCode: languageCode),
                    systemImage: "person.badge.plus",
                    action: onCreateAccount
                )
                FGSecondaryButton(
                    title: L10n.t("discover_guest_sign_in_button", languageCode: languageCode),
                    systemImage: "person.fill",
                    action: onSignIn
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// Polished locked preview for Discover when ``MapViewModel/isGuestDiscoverMode`` (same fan auth sheet as Account).
private struct GuestDiscoverLockedPreviewCard<Preview: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let accent: Color
    let headline: String
    @ViewBuilder var teaser: () -> Preview
    let onLogIn: () -> Void
    let onCreateAccount: () -> Void
    let onDismiss: () -> Void
    var onNotNow: (() -> Void)?

    var body: some View {
        FGCard {
            HStack(alignment: .top, spacing: FGSpacing.md) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(colorScheme == .dark ? 0.22 : 0.14))
                        .frame(width: 44, height: 44)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(accent)
                }

                VStack(alignment: .leading, spacing: FGSpacing.xs) {
                    Text(headline)
                        .font(FGTypography.caption.weight(.heavy))
                        .foregroundStyle(accent)

                    Text(GuestDiscoverLockedCopy.body)
                        .font(FGTypography.body)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider()
                .overlay(FGColor.divider(colorScheme))

            teaser()

            VStack(spacing: FGSpacing.sm) {
                FGPrimaryButton(title: "Log In", action: onLogIn)
                FGSecondaryButton(title: "Create Account", action: onCreateAccount)
                if let onNotNow {
                    FGSecondaryButton(title: "Not now", action: onNotNow)
                }
            }
        }
        .frame(maxHeight: 420)
    }
}

/// Primary map experience: search, date strip, clustered annotations, venue preview, and sheets for detail, comments, and vibes.
struct DiscoverScreen: View {

    @ObservedObject var viewModel: MapViewModel
    @ObservedObject private var fanUpdatesStore: FanUpdatesRealtimeStore
    /// Intentionally not `@ObservedObject`: Chat publishes (unread/loading/inbox) must not rebuild Discover.
    /// Friendship chips for live-energy use equality-gated `@State` via `onReceive`.
    let chatViewModel: ChatViewModel
    @StateObject private var searchSuggestionController = DiscoverSearchSuggestionController()
    @StateObject private var discoverFanSearchController = DiscoverFanSearchController()
    @StateObject private var discoverProGameSearchController = DiscoverProGameSearchController()
    @State private var discoverProGameDetailMatch: LiveMatch?
    @State private var acceptedFriendUserIDs: Set<UUID> = []
    @Binding var isCalendarOverlayPresented: Bool
    let isDiscoverTabSelected: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @FocusState private var isSearchFocused: Bool
    /// Session-only Discover search result chip; resets to ``DiscoverSearchResultFilter/all`` when search closes.
    @State private var discoverSearchResultFilter: DiscoverSearchResultFilter = .all
    /// Keyboard overlap with the Discover layout (points from the bottom). 0 when dismissed.
    @State private var discoverSearchKeyboardBottomOverlap: CGFloat = 0
    @State private var showVenueDetails = false
    @State private var showDatePicker = false
    @State private var discoverDatePickerSelection: Date?
    /// Month shown in the Discover calendar overlay (drives dot loads when switching Venues / Pickup).
    @State private var discoverCalendarDisplayedMonth = Date()
    @State private var fanUpdatesSheetEvent: FanUpdatesSheetEvent?
    @State private var predictionSheet: DiscoverPredictionSheetContext?
    @State private var showVenueRatingSheet = false
    @State private var fanFeatureGateAlertMessage: String?
    @State private var showUnclaimedBusinessAccountRequiredConfirm = false
    @State private var showUnclaimedOwnerClaimConfirm = false
    @State private var pendingUnclaimedClaimBar: BarVenue?
    @State private var venuePreviewFanZoneCache: [String: VenuePreviewFanZoneData] = [:]
    @State private var venuePreviewFanZoneRefreshInFlightKeys: Set<String> = []
    @State private var venuePreviewFanZoneSavingKeys: Set<String> = []
    @State private var mapVenueReloadTask: Task<Void, Never>?
    @State private var lastMapVenueReloadRegion: MKCoordinateRegion?
    /// Multi-venue map cluster: sheet lists venues after tap (zoom runs first).
    @State private var clusterForSheet: VenueCluster?
    /// After opening Account from the Discover gate, restore this venue once fan login succeeds.
    @State private var pendingResumeVenueIDAfterLogin: UUID?
    /// Bumps when returning to foreground so map user-dot visibility refreshes after Settings changes.
    @State private var discoverMapLocationAuthVersion = 0
    @State private var discoverLocationHint: String?
    @State private var mapDisplayModeHintText: String?
    @State private var mapDisplayModeHintTask: Task<Void, Never>?
    @State private var mapActivityWowEvalTask: Task<Void, Never>?
    @State private var discoverTopAdLoadFailed = false
    @State private var discoverBottomAdLoaded = false
    @State private var discoverBottomAdRetryToken = 0
    @State private var discoverBottomAdRetryTask: Task<Void, Never>?
    @State private var discoverBottomAdNoFillRetryCount = 0
    @State private var discoverBottomAdBackoffUntil: Date?
    @State private var showDiscoverSportMoreSheet = false
    @State private var showDiscoverHelpSheet = false
    @State private var showFirstLaunchLanguageSelector = false
    @State private var didPresentFirstLaunchLanguageThisSession = false
    /// When non-nil, dismissing the language selector marks post-account-creation completion for this user.
    @State private var languageSelectorPostAccountCompletionUserId: UUID?
    @State private var firstLaunchDetectedLanguageCode = L10n.defaultLanguageCode
    @State private var didPresentStartupGuideThisSession = false
    @State private var pendingDiscoverActivityPanelIntro = false
    @State private var discoverActivityPanelExpansion: DiscoverActivityPanelState = .hidden
    @State private var discoverActivityPresentation = DiscoverActivityPanelPresentation.empty
    @State private var discoverActivityPresentationCacheKey: DiscoverActivityPanelPresentationCacheKey?
    @State private var discoverPersonalizedInsightAnalyticsToken: String?
    @AppStorage(FavoriteTeamsStore.appStorageKey) private var discoverFavoriteTeamIDsRaw: String = ""
    @State private var discoverActivityPanelUserInteracted = false
    @State private var discoverActivityPanelAutoCollapseTask: Task<Void, Never>?
    @State private var discoverActivityPanelShownAnalytics = false
    @State private var discoverActivityPanelDidRestorePreference = false
    /// First-Discover intro active until the user explicitly interacts (not auto-collapse).
    @State private var discoverActivityPanelIntroActive = false
    @State private var discoverActivityPanelShowIntroInstruction = false
    @State private var discoverActivityPanelHandleAttentionToken: UInt = 0
    /// Last valid loaded Fans Nearby count for 0→positive pulse dedupe (session / account scoped).
    @State private var discoverFansNearbyLastLoadedCount: Int?
    @State private var discoverActivityLocalitySettleTask: Task<Void, Never>?
    @State private var discoverActivityLocalityLastBucket: (lat: Int, lng: Int)?
    @State private var pickupGameDetailNav: PickupDetailNavigationToken?
    @State private var pickupHostPrefillPlace: PickupPlaceRow?
    /// Discover empty-state Create Pickup Game (no place prefill). Same form as Going / place host.
    @State private var discoverEmptyCreatePickupFormMode: PickupGameFormMode?
    @State private var pickupPostCreateInviteGame: PickupGameRow?
    @State private var pickupPlaceClusterForSheet: PickupPlaceCluster?
    @State private var pendingPickupPlaceHostFromClusterDismiss: PickupPlaceRow?
    @State private var discoverWeather: DiscoverWeatherSnapshot?
    @State private var discoverWeatherRefreshTask: Task<Void, Never>?
    @State private var isDiscoverHomeCrowdToggleInFlight = false
    @State private var venuePreviewDetailEvent: SportsEvent?
    @State private var venueDetailOpenStartedAt: CFAbsoluteTime?
    @Namespace private var discoverModeToggleNamespace
    private let livePulseThreshold = VenueMapEnergyScore.hotPulseThreshold
    @State private var discoverAnnotationCache = DiscoverAnnotationCache.empty
    @State private var lastDiscoverTabConsistencyAt: Date?

    private static let discoverTabConsistencyTTL: TimeInterval = 20

    private func isPassiveDiscoverTabConsistencyTrigger(_ trigger: String) -> Bool {
        trigger == "tabVisible" || trigger == "appear"
    }

    private var isPickupPlacesMode: Bool {
        viewModel.discoverMapContentMode == .pickupGames && viewModel.discoverPickupSubMode == .places
    }

    private struct DiscoverAnnotationCacheKey: Equatable {
        let mode: String
        let pickupSubMode: String
        let selectedDay: Int
        let selectedSport: String
        let searchText: String
        let mapDisplayMode: String
        let visibleLatitudeBucket: String
        let cameraCenterBucket: String
        let venueSnapshotKey: String
        let barsCount: Int
        let barsFingerprint: String
        let pickupGamesFingerprint: String
        let pickupPlacesFingerprint: String
    }

    private struct DiscoverAnnotationCounts: Equatable {
        let venue: Int
        let pickupGames: Int
        let pickupPlaces: Int

        var pickupTotal: Int {
            pickupGames + pickupPlaces
        }

        func renderedCount(mode: DiscoverMapContentMode) -> Int {
            mode == .pickupGames ? pickupTotal : venue
        }
    }

    private struct DiscoverAnnotationCache {
        let key: DiscoverAnnotationCacheKey?
        let venueClusters: [VenueCluster]
        let pickupGameClusters: [PickupGameCluster]
        let pickupPlaceClusters: [PickupPlaceCluster]
        let counts: DiscoverAnnotationCounts

        static let empty = DiscoverAnnotationCache(
            key: nil,
            venueClusters: [],
            pickupGameClusters: [],
            pickupPlaceClusters: [],
            counts: DiscoverAnnotationCounts(venue: 0, pickupGames: 0, pickupPlaces: 0)
        )
    }

    private struct VenueMapPinDisplayValues {
        let gamesToday: [SportsEvent]
        let goingTotal: Int
        let effectiveMode: MapViewModel.MapPinDisplayMode
        let isSelected: Bool
        let hasLiveNow: Bool
        let energy: Int
        let wantsEnriched: Bool
        let tint: Color
        let displayClass: VenuePinDisplayClass
    }

    private struct VenueClusterDisplayValues {
        let energy: (maxScore: Int, dominantSport: String?)
        let displayState: ClusterDisplayState
        let tint: Color
        let isActive: Bool
        let displayClass: VenuePinDisplayClass
    }

    private struct PickupMapMarkerDisplayValues {
        let needed: Int
        let isSelected: Bool
        let badgeValue: String?
        let activity: PickupGameMapMarkerActivity
        let allowsPulse: Bool
        let accentColor: Color
        let reusedSportChipIcon: Bool
    }

    private let primaryMapUtilityButtonSize: CGFloat = 44
    private let secondaryMapUtilityButtonSize: CGFloat = 44
    private let discoverLightGlassCornerRadius: CGFloat = 28
    private let mapUtilityStackSpacing: CGFloat = 8
    private let discoverFilterRowSpacing: CGFloat = 6

    private struct VenuePreviewMiniStat: Identifiable {
        let id: String
        let symbol: String
        let label: String
        let countColor: Color
        let background: Color
        let selectedBackground: Color
    }

    private struct VenuePreviewStableGameItem: Identifiable {
        let id: String
        let index: Int
        let event: SportsEvent
    }

    private struct VenuePreviewHeroCardPresentation {
        let renderKey: String
        let gameTitle: String
        let sport: String
        let league: String
        let sportDisplay: VenuePreviewSportDisplayModel
        let dateTimeText: String
        let chatTitle: String
        let venueEventID: UUID?
        let matchup: VenuePreviewMatchup
        let homeTheme: TeamTheme
        let awayTheme: TeamTheme
        let homeOrb: VenuePreviewTeamOrbDisplayModel
        let awayOrb: VenuePreviewTeamOrbDisplayModel
        let homeTitle: String
        let awayTitle: String
    }

    /// Classic football-club crest silhouette (generic, not any official mark).
    private struct VenueSoccerClubShieldShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let width = rect.width
            let height = rect.height
            path.move(to: CGPoint(x: width * 0.5, y: 0))
            path.addLine(to: CGPoint(x: width * 0.94, y: height * 0.18))
            path.addLine(to: CGPoint(x: width * 0.82, y: height))
            path.addLine(to: CGPoint(x: width * 0.18, y: height))
            path.addLine(to: CGPoint(x: width * 0.06, y: height * 0.18))
            path.closeSubpath()
            return path
        }
    }

    /// Shallow host that owns preview chrome. Keeps DiscoverScreen’s `venuePreviewCard` opaque return
    /// from baking the entire scroll/hero tree into one explosively nested generic type.
    private struct DiscoverMapVenuePreviewCardHost<Content: View, Actions: View>: View {
        let venueId: UUID
        let chromeMaterial: Material
        let chromeTint: Color
        let chromeBorder: Color
        let colorScheme: ColorScheme
        @ViewBuilder let content: () -> Content
        @ViewBuilder let actions: () -> Actions

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                content()
                actions()
            }
            .padding(.horizontal, FGSpacing.lg)
            .padding(.vertical, FGSpacing.md)
            .frame(maxHeight: 512)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous)
                        .fill(chromeMaterial)
                    RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous)
                        .fill(chromeTint)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous)
                    .strokeBorder(chromeBorder, lineWidth: 1)
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.34 : 0.14),
                radius: colorScheme == .dark ? 24 : 16,
                x: 0,
                y: colorScheme == .dark ? 14 : 9
            )
            .shadow(color: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.08 : 0.04), radius: 12, x: 0, y: 2)
            .id(venueId)
        }
    }

    /// Pro-style collapsed hero game card for the map venue preview (presentation only).
    /// Intentionally **non-generic**: prior `@ViewBuilder` slots exploded SwiftUI type metadata
    /// inside `venuePreviewCard` and overflowed the main-thread stack on open.
    private struct VenuePreviewProHeroGameCard: View {
        @Environment(\.colorScheme) private var colorScheme

        let homeTheme: TeamTheme
        let awayTheme: TeamTheme
        let homeTitle: String
        let awayTitle: String
        let hasResolvedTeams: Bool
        let fallbackTitle: String
        let sportLabel: String
        let sportIconName: String
        let dateTimeText: String
        let eventId: String
        let goingCount: Int
        let avatarProfiles: [UserProfileRow]
        let viewerUserID: UUID?
        let showsGoingSection: Bool
        let goingAlreadyInterested: Bool
        let goingIsPending: Bool
        let goingIsDisabled: Bool
        let chatCommentCount: Int
        let chatIsDisabled: Bool
        let showsPredictionRow: Bool
        let predictionVoteCount: Int
        let predictionConsensusText: String?
        /// Guest Discover: show conversion leaf instead of Going/Chat/Predictions.
        let showsGuestInteraction: Bool
        let languageCode: String
        let onCardTap: () -> Void
        let onGoingTap: () -> Void
        let onChatTap: () -> Void
        let onPredictionTap: () -> Void
        let onGuestCreateAccount: () -> Void
        let onGuestSignIn: () -> Void

        private let cornerRadius: CGFloat = 26

        var body: some View {
            VStack(spacing: 0) {
                matchupHero
                    .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .onTapGesture {
                        onCardTap()
                    }

                if showsGoingSection {
                    VStack(spacing: 10) {
                        goingSocialProofRow

                        if showsGuestInteraction {
                            GuestGameInteractionSection(
                                languageCode: languageCode,
                                onCreateAccount: onGuestCreateAccount,
                                onSignIn: onGuestSignIn,
                                usesDarkHeroChrome: true
                            )
                        } else {
                            HStack(spacing: 10) {
                                goingButton
                                    .frame(maxWidth: .infinity)

                                chatButton
                                    .frame(maxWidth: .infinity)
                            }

                            if showsPredictionRow {
                                predictionButton
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background {
                        LinearGradient(
                            colors: [
                                Color.black.opacity(colorScheme == .dark ? 0.52 : 0.62),
                                Color(red: 0.03, green: 0.06, blue: 0.14).opacity(0.94)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.14 : 0.10), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.38 : 0.16), radius: 18, y: 10)
        }

        private var goingButton: some View {
            let fill = goingAlreadyInterested
                ? LinearGradient(
                    colors: [Color(red: 0.00, green: 0.72, blue: 0.34), Color(red: 0.00, green: 0.52, blue: 0.24)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                : LinearGradient(
                    colors: [
                        FGColor.accentGreen.opacity(colorScheme == .dark ? 0.22 : 0.14),
                        FGColor.accentGreen.opacity(colorScheme == .dark ? 0.14 : 0.08)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            let foreground = goingAlreadyInterested ? Color.white : FGColor.accentGreen

            return Button(action: onGoingTap) {
                HStack(spacing: 6) {
                    if goingIsPending {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(foreground)
                    } else {
                        Image(systemName: goingAlreadyInterested ? "checkmark" : "plus")
                            .font(.caption.weight(.black))
                    }
                    Text(goingAlreadyInterested ? "Going" : "Going?")
                        .font(FGTypography.metadata.weight(.heavy))
                        .lineLimit(1)
                }
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background {
                    Capsule(style: .continuous)
                        .fill(fill)
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(FGColor.accentGreen.opacity(goingAlreadyInterested ? 0.36 : 0.24), lineWidth: 1)
                }
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(goingIsDisabled)
            .opacity(goingIsDisabled ? 0.68 : 1)
            .accessibilityLabel(goingAlreadyInterested ? "Going" : "Mark as going")
        }

        private var chatButton: some View {
            Button(action: onChatTap) {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.caption.weight(.bold))
                    Text("Chat")
                        .font(FGTypography.metadata.weight(.heavy))
                        .lineLimit(1)
                    if chatCommentCount > 0 {
                        Circle()
                            .fill(FGColor.accentBlue)
                            .frame(width: 7, height: 7)
                    }
                }
                .foregroundStyle(.white.opacity(0.92))
                .frame(maxWidth: .infinity, minHeight: 40)
                .background {
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.14 : 0.10),
                                    Color.black.opacity(colorScheme == .dark ? 0.34 : 0.28)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.12), lineWidth: 1)
                }
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(chatIsDisabled)
            .opacity(chatIsDisabled ? 0.62 : 1)
            .accessibilityLabel(
                chatCommentCount > 0
                    ? "Chat, \(chatCommentCount) comments"
                    : "Chat"
            )
        }

        private var predictionButton: some View {
            Button(action: onPredictionTap) {
                HStack(spacing: 10) {
                    Image(systemName: "trophy.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(FGColor.accentYellow)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fan Predictions")
                            .font(FGTypography.caption.weight(.heavy))
                            .foregroundStyle(.white.opacity(0.94))
                            .lineLimit(1)

                        if let predictionConsensusText {
                            Text(predictionConsensusText)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.58))
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                        }
                    }

                    Spacer(minLength: 6)

                    if predictionVoteCount > 0 {
                        Text(predictionVoteCount == 1 ? "1 fan voted" : "\(predictionVoteCount) fans voted")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                    }

                    Text("Open")
                        .font(FGTypography.caption.weight(.bold))
                        .foregroundStyle(FGColor.accentGreen)

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(FGColor.accentGreen.opacity(0.88))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.07 : 0.06))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.08), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
        }

        private var matchupHero: some View {
            ZStack {
                safeVenueGameGradient(
                    homeTheme: homeTheme,
                    awayTheme: awayTheme,
                    eventId: eventId,
                    cardVariant: "proHero"
                )

                LinearGradient(
                    colors: [
                        Color.black.opacity(colorScheme == .dark ? 0.18 : 0.10),
                        Color.black.opacity(colorScheme == .dark ? 0.44 : 0.34),
                        Color(red: 0.02, green: 0.04, blue: 0.12).opacity(0.88)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: [
                        homeTheme.accentColor.opacity(0.22),
                        Color.clear
                    ],
                    center: .leading,
                    startRadius: 12,
                    endRadius: 180
                )

                RadialGradient(
                    colors: [
                        awayTheme.accentColor.opacity(0.20),
                        Color.clear
                    ],
                    center: .trailing,
                    startRadius: 12,
                    endRadius: 180
                )

                VStack(spacing: 0) {
                    HStack(alignment: .top) {
                        sportBadge
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)

                    Spacer(minLength: 6)

                    if hasResolvedTeams {
                        let badgeSize = resolvedHeroBadgeSize()

                        HStack(alignment: .center, spacing: 6) {
                            teamMatchupBadge(
                                theme: homeTheme,
                                title: homeTitle,
                                rawTeamName: homeTheme.rawName,
                                badgeSize: badgeSize
                            )
                            .frame(width: badgeSize, alignment: .center)

                            GeometryReader { geometry in
                                let layout = matchupHeroLayoutMetrics(
                                    centerWidth: geometry.size.width,
                                    badgeSize: badgeSize
                                )

                                matchupCenterColumn(layout: layout)
                                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: matchupHeroCenterStackHeight)

                            teamMatchupBadge(
                                theme: awayTheme,
                                title: awayTitle,
                                rawTeamName: awayTheme.rawName,
                                badgeSize: badgeSize
                            )
                            .frame(width: badgeSize, alignment: .center)
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                    } else {
                        Text(fallbackTitle)
                            .font(.system(size: 22, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.72)
                            .padding(.horizontal, 20)

                        dateTimeRow
                            .padding(.top, 8)
                            .padding(.bottom, 14)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: showsGoingSection ? 208 : 200)
        }

        private var sportBadge: some View {
            HStack(spacing: 6) {
                Image(systemName: safeSportIconName)
                    .font(.system(size: 11, weight: .black))
                Text(safeSportLabel)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.88))
            .textCase(.uppercase)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.10))
            }
        }

        private func resolvedHeroBadgeSize() -> CGFloat {
            switch max(safeHomeTitle.count, safeAwayTitle.count) {
            case ...11:
                return 92
            case ...16:
                return 88
            default:
                return 84
            }
        }

        private var matchupHeroCenterStackHeight: CGFloat {
            let typography = matchupCenterTypography(
                longestTitleLength: max(safeHomeTitle.count, safeAwayTitle.count)
            )
            let estimatedCenterWidth: CGFloat = 128
            let homeBlock = matchupTeamBlockHeight(
                title: safeHomeTitle,
                fontSize: typography.teamSize,
                availableWidth: estimatedCenterWidth
            )
            let awayBlock = matchupTeamBlockHeight(
                title: safeAwayTitle,
                fontSize: typography.teamSize,
                availableWidth: estimatedCenterWidth
            )
            return homeBlock + awayBlock + typography.vsSize + 22
        }

        private struct MatchupHeroLayoutMetrics {
            let badgeSize: CGFloat
            let centerWidth: CGFloat
            let typography: MatchupCenterTypography
            let homeTeamBlockHeight: CGFloat
            let awayTeamBlockHeight: CGFloat
        }

        private struct MatchupCenterTypography {
            let teamSize: CGFloat
            let vsSize: CGFloat
            let minimumScaleFactor: CGFloat
        }

        private func matchupHeroLayoutMetrics(
            centerWidth: CGFloat,
            badgeSize: CGFloat
        ) -> MatchupHeroLayoutMetrics {
            let longestTitleLength = max(safeHomeTitle.count, safeAwayTitle.count)
            let typography = matchupCenterTypography(longestTitleLength: longestTitleLength)
            let homeTeamBlockHeight = matchupTeamBlockHeight(
                title: safeHomeTitle,
                fontSize: typography.teamSize,
                availableWidth: centerWidth
            )
            let awayTeamBlockHeight = matchupTeamBlockHeight(
                title: safeAwayTitle,
                fontSize: typography.teamSize,
                availableWidth: centerWidth
            )

            return MatchupHeroLayoutMetrics(
                badgeSize: badgeSize,
                centerWidth: centerWidth,
                typography: typography,
                homeTeamBlockHeight: homeTeamBlockHeight,
                awayTeamBlockHeight: awayTeamBlockHeight
            )
        }

        private func matchupCenterColumn(layout: MatchupHeroLayoutMetrics) -> some View {
            VStack(spacing: 3) {
                matchupTeamNameText(
                    safeHomeTitle,
                    typography: layout.typography,
                    availableWidth: layout.centerWidth,
                    blockHeight: layout.homeTeamBlockHeight,
                    color: .white.opacity(0.96)
                )

                Text("VS")
                    .font(.system(size: layout.typography.vsSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
                    .tracking(1.2)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)

                matchupTeamNameText(
                    safeAwayTitle,
                    typography: layout.typography,
                    availableWidth: layout.centerWidth,
                    blockHeight: layout.awayTeamBlockHeight,
                    color: FGColor.accentGreen.opacity(0.98)
                )

                dateTimeRow
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .layoutPriority(1)
        }

        private func matchupTeamNameText(
            _ title: String,
            typography: MatchupCenterTypography,
            availableWidth: CGFloat,
            blockHeight: CGFloat,
            color: Color
        ) -> some View {
            Text(title)
                .font(.system(size: typography.teamSize, weight: .heavy, design: .rounded))
                .foregroundStyle(color)
                .frame(maxWidth: availableWidth)
                .frame(height: blockHeight, alignment: .center)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(typography.minimumScaleFactor)
                .lineSpacing(-1)
                .allowsTightening(true)
        }

        private func matchupCenterTypography(longestTitleLength: Int) -> MatchupCenterTypography {
            let teamSize: CGFloat
            switch longestTitleLength {
            case ...11:
                teamSize = 28
            case ...16:
                teamSize = 26
            case ...20:
                teamSize = 22
            default:
                teamSize = 20
            }

            return MatchupCenterTypography(
                teamSize: teamSize,
                vsSize: 17,
                minimumScaleFactor: 0.75
            )
        }

        private func matchupTeamBlockHeight(
            title: String,
            fontSize: CGFloat,
            availableWidth: CGFloat
        ) -> CGFloat {
            if matchupTitleFitsSingleLine(title, fontSize: fontSize, availableWidth: availableWidth) {
                return fontSize * 1.14
            }
            return fontSize * 2.12
        }

        private func matchupTitleFitsSingleLine(
            _ title: String,
            fontSize: CGFloat,
            availableWidth: CGFloat
        ) -> Bool {
            let estimatedWidth = CGFloat(title.count) * fontSize * 0.50
            return estimatedWidth <= availableWidth
        }

        private var dateTimeRow: some View {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 9, weight: .bold))
                Text(safeDateTimeText)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
            }
            .foregroundStyle(.white.opacity(0.76))
        }

        private var goingSocialProofRow: some View {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "flame.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(FGColor.accentGreen)
                    Text(goingCount == 1 ? "1 Going" : "\(max(0, goingCount)) Going")
                        .font(FGTypography.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if !avatarProfiles.isEmpty {
                    GoingAvatarStack(
                        profiles: Array(avatarProfiles.prefix(4)),
                        viewerUserID: viewerUserID,
                        diameter: 24
                    )
                }
            }
        }

        @ViewBuilder
        private func teamMatchupBadge(
            theme: TeamTheme,
            title: String,
            rawTeamName: String,
            badgeSize: CGFloat
        ) -> some View {
            let selection = ManualVenueTeamResolver.resolve(rawTeamName)
            switch selection.type {
            case .country:
                nationalTeamCountryBadge(
                    theme: theme,
                    title: title,
                    badgeSize: badgeSize,
                    flag: selection.flag ?? theme.flag
                )
            case .club, .custom:
                clubTeamCrestBadge(
                    theme: theme,
                    title: title,
                    rawTeamName: rawTeamName,
                    badgeSize: badgeSize,
                    favoriteClub: favoriteClubTeam(for: selection)
                )
            }
        }

        private func favoriteClubTeam(for selection: ManualVenueTeamSelection) -> FavoriteTeam? {
            guard selection.type == .club else { return nil }
            return FavoriteTeamCatalog.searchTeams(selection.name).first { candidate in
                candidate.kind == .team
                    && candidate.name.caseInsensitiveCompare(selection.name) == .orderedSame
            }
        }

        private func nationalTeamCountryBadge(
            theme: TeamTheme,
            title: String,
            badgeSize: CGFloat,
            flag: String?
        ) -> some View {
            let safeFlag = TeamTheme.safeFlag(flag)
            let fallback = TeamTheme.safeFallbackText(
                rawName: theme.rawName,
                displayName: title,
                shortName: theme.shortName
            )
            let primaryColor = orbThemeColor(theme, index: 0)
            let secondaryColor = orbThemeColor(theme, index: 1)
            let flagDiameter = badgeSize * 0.94
            let flagFontSize = flagDiameter * 0.92
            let initialsFontSize = badgeSize * 0.24

            return ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                primaryColor.opacity(1.0),
                                secondaryColor.opacity(0.94),
                                primaryColor.opacity(0.82)
                            ],
                            center: UnitPoint(x: 0.38, y: 0.30),
                            startRadius: 2,
                            endRadius: badgeSize * 0.58
                        )
                    )

                if let safeFlag {
                    Text(safeFlag)
                        .font(.system(size: flagFontSize))
                        .frame(width: flagDiameter, height: flagDiameter)
                        .minimumScaleFactor(0.92)
                        .lineLimit(1)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
                } else {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    primaryColor.opacity(0.96),
                                    secondaryColor.opacity(0.78)
                                ],
                                center: .topLeading,
                                startRadius: 4,
                                endRadius: badgeSize * 0.56
                            )
                        )
                    Text(fallback.isEmpty ? "FG" : fallback)
                        .font(.system(size: initialsFontSize, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.30), radius: 4, y: 2)
                }

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(0.48),
                                Color.white.opacity(0.10),
                                Color.clear
                            ],
                            center: UnitPoint(x: 0.28, y: 0.18),
                            startRadius: 1,
                            endRadius: badgeSize * 0.46
                        )
                    )
                    .blendMode(.softLight)
                    .allowsHitTesting(false)

                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.42),
                                Color.white.opacity(0.14),
                                primaryColor.opacity(0.35)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.25
                    )
            }
            .frame(width: badgeSize, height: badgeSize)
            .shadow(color: .black.opacity(0.36), radius: 10, y: 6)
            .shadow(color: primaryColor.opacity(0.24), radius: 12, y: 4)
            .accessibilityHidden(true)
        }

        private func clubTeamCrestBadge(
            theme: TeamTheme,
            title: String,
            rawTeamName: String,
            badgeSize: CGFloat,
            favoriteClub: FavoriteTeam?
        ) -> some View {
            let crestText = clubCrestLabel(
                theme: theme,
                title: title,
                favoriteClub: favoriteClub
            )
            let primaryColor = favoriteClub?.badgeColor ?? orbThemeColor(theme, index: 0)
            let secondaryColor = favoriteClub.map {
                Color(
                    red: min(1, $0.badgeRed * 0.72),
                    green: min(1, $0.badgeGreen * 0.72),
                    blue: min(1, $0.badgeBlue * 0.72)
                )
            } ?? orbThemeColor(theme, index: 1)
            let crestWidth = badgeSize * 0.92
            let crestHeight = badgeSize * 1.04
            let initialsFontSize = badgeSize * 0.30

            return ZStack {
                VenueSoccerClubShieldShape()
                    .fill(
                        LinearGradient(
                            colors: [
                                primaryColor.opacity(0.98),
                                secondaryColor.opacity(0.88),
                                primaryColor.opacity(0.72)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                VenueSoccerClubShieldShape()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(0.34),
                                Color.white.opacity(0.08),
                                Color.clear
                            ],
                            center: UnitPoint(x: 0.34, y: 0.16),
                            startRadius: 1,
                            endRadius: crestHeight * 0.52
                        )
                    )
                    .blendMode(.softLight)
                    .allowsHitTesting(false)

                Text(crestText)
                    .font(.system(size: initialsFontSize, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.68)
                    .lineLimit(1)
                    .padding(.horizontal, crestWidth * 0.12)
                    .padding(.top, crestHeight * 0.08)
                    .shadow(color: .black.opacity(0.34), radius: 4, y: 2)

                VenueSoccerClubShieldShape()
                    .overlay {
                        VenueSoccerClubShieldShape()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.46),
                                        Color.white.opacity(0.16),
                                        primaryColor.opacity(0.42)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.35
                            )
                    }
            }
            .frame(width: crestWidth, height: crestHeight)
            .shadow(color: .black.opacity(0.36), radius: 10, y: 6)
            .shadow(color: primaryColor.opacity(0.26), radius: 12, y: 4)
            .accessibilityLabel("\(rawTeamName) club crest")
        }

        private func clubCrestLabel(
            theme: TeamTheme,
            title: String,
            favoriteClub: FavoriteTeam?
        ) -> String {
            if let shortCode = favoriteClub?.shortCode?.trimmingCharacters(in: .whitespacesAndNewlines),
               !shortCode.isEmpty {
                return shortCode.uppercased()
            }
            if let shortName = theme.shortName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !shortName.isEmpty {
                return shortName.uppercased()
            }
            return TeamTheme.safeFallbackText(
                rawName: theme.rawName,
                displayName: title,
                shortName: theme.shortName
            )
        }

        private func orbThemeColor(_ theme: TeamTheme, index: Int) -> Color {
            guard !theme.usesFallback, theme.colors.indices.contains(index) else {
                return index == 0 ? FGColor.accentGreen : Color(red: 0.02, green: 0.05, blue: 0.14)
            }
            return theme.colors[index]
        }

        private var safeHomeTitle: String {
            let trimmed = homeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "HOME" : trimmed.uppercased()
        }

        private var safeAwayTitle: String {
            let trimmed = awayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "AWAY" : trimmed.uppercased()
        }

        private var safeSportLabel: String {
            let trimmed = sportLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "SPORT" : trimmed.uppercased()
        }

        private var safeDateTimeText: String {
            let trimmed = dateTimeText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Time TBD" : trimmed
        }

        private var safeSportIconName: String {
            let trimmed = sportIconName.trimmingCharacters(in: .whitespacesAndNewlines)
            let allowed: Set<String> = [
                "sportscourt.fill", "soccerball", "basketball.fill", "football.fill",
                "baseball.fill", "hockey.puck.fill", "tennisball.fill", "figure.run",
                "flag.checkered", "trophy.fill"
            ]
            return allowed.contains(trimmed) ? trimmed : "sportscourt.fill"
        }
    }

    private struct VenuePreviewSportDisplayModel {
        let displaySport: String
        let displayLeague: String
        let badgeLabel: String
        let iconName: String
        let color: Color
        let isFallback: Bool
    }

    private struct VenuePreviewTeamOrbDisplayModel: Equatable {
        let rawName: String
        let displayName: String
        let safeFlag: String?
        let fallbackText: String
        let usesFallbackTheme: Bool
    }

    private struct VenuePreviewMatchup {
        let home: String
        let away: String
        let hasResolvedTeams: Bool
    }

    private struct VenuePreviewIdentityBanner {
        let rawIdentity: String?
        let displayName: String
        let flag: String?
    }

    private struct VenuePreviewFanZoneData {
        let cacheKey: String
        let venueID: UUID
        let vibeTargetEventID: UUID?
        let eventIDs: [UUID]
        let fireCount: Int
        let seatingCount: Int
        let tvCount: Int
        let audioCount: Int
        let crowdCount: Int
        let selectedVibes: Set<String>
        let savingVibes: Set<String>
        let isFromCache: Bool

        var fingerprint: String {
            [
                cacheKey,
                vibeTargetEventID?.uuidString.lowercased() ?? "nil",
                eventIDs.map { $0.uuidString.lowercased() }.joined(separator: ","),
                "\(fireCount)",
                "\(seatingCount)",
                "\(tvCount)",
                "\(audioCount)",
                "\(crowdCount)",
                selectedVibes.sorted().joined(separator: ",")
            ].joined(separator: "|")
        }
    }

    private struct VenuePreviewFanZoneBlockView: View {
        @Environment(\.colorScheme) private var colorScheme
        @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
        @State private var showCommunityVerifiedInfo = false
        @State private var showVenueEnergyInfo = false

        /// Human-readable Venue Energy caption for the selected day (never the raw algorithm score).
        let venueEnergyCaption: String?
        let fireCount: Int
        let seatingCount: Int
        let tvCount: Int
        let audioCount: Int
        let crowdCount: Int
        let selectedVibes: Set<String>
        let savingVibes: Set<String>
        let isVotingEnabled: Bool
        let showsUnclaimedBusinessNote: Bool
        let onVote: (_ debugType: String, _ vibeType: String) -> Void

        private var languageCode: String {
            L10n.normalizedLanguageCode(appLanguageRaw)
        }

        private struct MetricItem: Identifiable {
            let id: String
            let debugType: String
            let symbol: String
            let count: Int
            let tint: Color
            let labelKey: String
        }

        private var metrics: [MetricItem] {
            [
                MetricItem(
                    id: "packed",
                    debugType: "fire",
                    symbol: "🔥",
                    count: fireCount,
                    tint: FGColor.dangerRed,
                    labelKey: "community_metric_great_atmosphere"
                ),
                MetricItem(
                    id: "seats_open",
                    debugType: "seating",
                    symbol: "🪑",
                    count: seatingCount,
                    tint: FGColor.accentGreen,
                    labelKey: "community_metric_seating_available"
                ),
                MetricItem(
                    id: "tv_visible",
                    debugType: "tv",
                    symbol: "📺",
                    count: tvCount,
                    tint: FGColor.accentBlue,
                    labelKey: "community_metric_tvs_available"
                ),
                MetricItem(
                    id: "audio_on",
                    debugType: "audio",
                    symbol: "🔊",
                    count: audioCount,
                    tint: Color.orange,
                    labelKey: "community_metric_game_sound"
                ),
                MetricItem(
                    id: "crowd",
                    debugType: "crowd",
                    symbol: "👥",
                    count: crowdCount,
                    tint: Color(red: 0.00, green: 0.58, blue: 0.72),
                    labelKey: "community_metric_crowded"
                )
            ]
        }

        var body: some View {
            VStack(alignment: .center, spacing: 8) {
                venueEnergyHeader

                communityVerifiedHeader

                HStack(spacing: 0) {
                    ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                        communityMetricCell(metric)
                            .frame(maxWidth: .infinity, minHeight: Self.metricCardMinHeight, alignment: .top)

                        if index < metrics.count - 1 {
                            Rectangle()
                                .fill(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.55 : 0.42))
                                .frame(width: 1, height: 44)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .zIndex(6)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .center)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .allowsHitTesting(true)
            .zIndex(5)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .allowsHitTesting(false)
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                FGColor.accentGreen.opacity(colorScheme == .dark ? 0.16 : 0.09),
                                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.14 : 0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.38), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.10 : 0.06), radius: 14, y: 6)
            .alert(
                L10n.t("community_verified", languageCode: languageCode),
                isPresented: $showCommunityVerifiedInfo
            ) {
                Button(L10n.t("done", languageCode: languageCode), role: .cancel) {}
            } message: {
                Text(communityVerifiedInfoMessage)
            }
            .sheet(isPresented: $showVenueEnergyInfo) {
                VenueEnergyHowItWorksSheet(audience: .fan)
            }
        }

        private var venueEnergyHeader: some View {
            HStack(spacing: 2) {
                Text("Venue Energy")
                    .font(FGTypography.metadata.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .accessibilityAddTraits(.isHeader)

                if let venueEnergyCaption, !venueEnergyCaption.isEmpty {
                    Text(venueEnergyCaption)
                        .font(FGTypography.metadata.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }

                VenueEnergyInfoButton(action: {
                    showVenueEnergyInfo = true
                }, tint: FGColor.accentBlue)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .accessibilityElement(children: .contain)
        }

        private var communityVerifiedInfoMessage: String {
            var message = L10n.t("community_verified_info_message", languageCode: languageCode)
            if showsUnclaimedBusinessNote {
                message += "\n\n" + L10n.t("venue_fan_confirmations_unclaimed_note", languageCode: languageCode)
            }
            return message
        }

        /// Shared metric-card height so one-line labels (e.g. Crowded) do not shrink a cell.
        private static let metricCardMinHeight: CGFloat = 78
        private static let metricLabelMinHeight: CGFloat = 22
        private static let metricVoteLineHeight: CGFloat = 14
        private static let metricIconSize: CGFloat = 26
        private static let metricCornerRadius: CGFloat = 14

        private var communityVerifiedHeader: some View {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FGColor.accentGreen)
                        .accessibilityHidden(true)

                    Text(L10n.t("community_verified", languageCode: languageCode))
                        .font(FGTypography.metadata.weight(.bold))
                        .foregroundStyle(FGColor.accentGreen)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Text("•")
                        .font(FGTypography.metadata)
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .accessibilityHidden(true)

                    Text(L10n.t("community_verified_based_on", languageCode: languageCode))
                        .font(FGTypography.metadata)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    Button {
                        showCommunityVerifiedInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(FGColor.accentBlue)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.t("community_verified_info_a11y", languageCode: languageCode))
                }

                Text(L10n.t("community_vote_instruction", languageCode: languageCode))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .accessibilityHidden(true)

                if showsUnclaimedBusinessNote {
                    Text(L10n.t("venue_fan_confirmations_unclaimed_note", languageCode: languageCode))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.10 : 0.05))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.28 : 0.18), lineWidth: 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.t("community_verified_header_a11y", languageCode: languageCode))
            .accessibilityAddTraits(.isStaticText)
            .accessibilityAction(named: Text(L10n.t("community_verified_info_a11y", languageCode: languageCode))) {
                showCommunityVerifiedInfo = true
            }
        }

        private func communityMetricCell(_ metric: MetricItem) -> some View {
            let count = safeCount(metric.count)
            let isSelected = selectedVibes.contains(metric.id)
            let isSaving = savingVibes.contains(metric.id)
            let label = L10n.t(metric.labelKey, languageCode: languageCode)
            let voteCountText = localizedVoteCountText(count)
            let accent = isSelected ? Color.white : metric.tint
            let iconBackground = metric.tint.opacity(colorScheme == .dark ? 0.22 : 0.12)
            let voteHint = L10n.t("community_vote_double_tap_hint", languageCode: languageCode)

            return Button {
                onVote(metric.debugType, metric.id)
            } label: {
                VStack(spacing: 3) {
                    ZStack {
                        Circle()
                            .fill(iconBackground)
                            .frame(width: Self.metricIconSize, height: Self.metricIconSize)
                        if isSaving {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(accent)
                        } else {
                            Text(metric.symbol)
                                .font(.system(size: 13))
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(width: Self.metricIconSize, height: Self.metricIconSize)

                    Text(voteCountText)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                        .allowsTightening(true)
                        .frame(maxWidth: .infinity, minHeight: Self.metricVoteLineHeight, alignment: .center)

                    Text(label)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.92) : FGColor.secondaryText(colorScheme))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.72)
                        .frame(maxWidth: .infinity, minHeight: Self.metricLabelMinHeight, alignment: .top)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background {
                    RoundedRectangle(cornerRadius: Self.metricCornerRadius, style: .continuous)
                        .fill(isSelected ? metric.tint.opacity(colorScheme == .dark ? 0.86 : 0.82) : Color.clear)
                }
                .contentShape(RoundedRectangle(cornerRadius: Self.metricCornerRadius, style: .continuous))
            }
            .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.965, hapticOnPress: false))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .disabled(isSaving)
            .opacity(isVotingEnabled ? 1 : 0.54)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label). \(voteCountText). \(voteHint)")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        }

        private func localizedVoteCountText(_ count: Int) -> String {
            let safe = safeCount(count)
            if safe == 1 {
                return L10n.t("community_vote_count_one", languageCode: languageCode)
            }
            return String(
                format: L10n.t("community_vote_count_other", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                safe
            )
        }

        private func safeCount(_ value: Int) -> Int {
            max(0, value)
        }
    }

    private struct VenueGameCardSnapshotObservedContent<Content: View>: View {
        @ObservedObject var store: VenueGameCardSnapshotStore
        let content: () -> Content

        var body: some View {
            content()
        }
    }

    private struct DiscoverVenuePredictionVisibility {
        let eventID: UUID?
        let sportType: String
        let teams: VenueEventPredictionTeams?
        let hasHomeTeam: Bool
        let hasAwayTeam: Bool
        let startsAt: Date?
        let lockTime: Date?
        let isLocked: Bool
        let isCancelled: Bool
        let hiddenReason: String?

        var shouldRender: Bool {
            hiddenReason == nil
        }

        var predictionVisible: Bool { hiddenReason == nil }
    }

    init(
        viewModel: MapViewModel,
        chatViewModel: ChatViewModel,
        isCalendarOverlayPresented: Binding<Bool>,
        isDiscoverTabSelected: Bool = true
    ) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        _fanUpdatesStore = ObservedObject(wrappedValue: viewModel.fanUpdatesStore)
        self.chatViewModel = chatViewModel
        _isCalendarOverlayPresented = isCalendarOverlayPresented
        self.isDiscoverTabSelected = isDiscoverTabSelected
    }

    var body: some View {
        let _ = SwiftUIRecompPerf.rootBodyEvaluated(screen: "Discover")
        discoverScreenWithToolbar
            .onAppear {
                refreshAcceptedFriendUserIDs(reason: "appear")
            }
            .onChange(of: viewModel.canUseFanSocialFeatures) { _, _ in
                refreshAcceptedFriendUserIDs(reason: "socialGate")
            }
            .onReceive(chatViewModel.$friendshipChipByOtherUserId) { chips in
                refreshAcceptedFriendUserIDs(from: chips, reason: "friendshipChips")
            }
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
            SwiftUIRecompPerf.identicalSnapshotSkipped(source: "discover.acceptedFriends.\(reason)", rows: next.count)
            return
        }
        acceptedFriendUserIDs = next
        SwiftUIRecompPerf.immutableSnapshotPublished(source: "discover.acceptedFriends.\(reason)", rows: next.count)
        SwiftUIRecompPerf.rootInvalidated(screen: "Discover", source: "acceptedFriends.\(reason)")
    }

    private var discoverScreenWithToolbar: some View {
        discoverScreenWithTertiarySheets
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(L10n.t("discover_search_keyboard_dismiss", languageCode: L10n.normalizedLanguageCode(appLanguageRaw))) {
                        dismissDiscoverSearchKeyboard()
                    }
                }
            }
            .onChange(of: discoverSummaryDataLoading) { wasLoading, isLoading in
                guard wasLoading, !isLoading, isDiscoverTabSelected else { return }
                scheduleMapActivityWowMomentEvaluation(reason: .dataSettled)
            }
            .onChange(of: viewModel.selectedSport) { previous, next in
                guard previous != next, isDiscoverTabSelected else { return }
                // Returning to All Sports must not create a bonus moment.
                guard next.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare("All") != .orderedSame else { return }
                scheduleMapActivityWowMomentEvaluation(
                    reason: .sportFilterChanged(from: previous, to: next)
                )
            }
    }

    private func scheduleMapActivityWowMomentEvaluation(reason: WowMomentOverlayManager.MapWowTrigger) {
        mapActivityWowEvalTask?.cancel()
        let expectedGeneration = viewModel.discoverMapRenderSnapshotGeneration
        let expectedSport = viewModel.selectedSport
        mapActivityWowEvalTask = Task { @MainActor in
            // Debounce after a real settled (!loading) transition — not an arbitrary readiness assumption.
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled else { return }
            guard isDiscoverTabSelected else { return }
            guard !discoverSummaryDataLoading else { return }
            guard expectedGeneration == viewModel.discoverMapRenderSnapshotGeneration else { return }
            if case .sportFilterChanged(_, let to) = reason {
                guard expectedSport == viewModel.selectedSport,
                      to == viewModel.selectedSport else { return }
            }
            let placeCount = viewModel.mapVisibleBars.reduce(into: 0) { partial, bar in
                if viewModel.venueHasVisibleGameToday(bar) {
                    partial += 1
                }
            }
#if DEBUG
            print("[WowMomentDebug] mapEval reason=\(reason) places=\(placeCount) sport=\(viewModel.selectedSport) gen=\(expectedGeneration)")
#endif
            viewModel.considerMapActivityWowMoment(
                placeCount: placeCount,
                selectedSport: viewModel.selectedSport,
                contentModeRaw: viewModel.discoverMapContentMode.rawValue,
                isLoading: discoverSummaryDataLoading,
                languageCode: appLanguageRaw,
                trigger: reason,
                expectedSnapshotGeneration: expectedGeneration
            )
        }
    }

    private var discoverScreenWithTertiarySheets: some View {
        discoverScreenWithClusterSheet
            .sheet(item: $pickupGameDetailNav) { token in
                DiscoverPickupGameDetailSheet(viewModel: viewModel, gameId: token.id)
                    .environmentObject(chatViewModel)
            }
            .sheet(isPresented: $showDiscoverSportMoreSheet) {
                DiscoverSportFilterMoreSheet(selectedSport: viewModel.selectedSport) { sport in
                    showDiscoverSportMoreSheet = false
                    discoverSelectSport(sport)
                }
            }
            .sheet(isPresented: $showDiscoverHelpSheet, onDismiss: {
                presentDiscoverActivityPanelIntroIfNeeded()
            }) {
                DiscoverHelpSheet(
                    personalizedDisplayName: FanGeoWelcomeDisplayName.sanitized(viewModel.currentUserDisplayName),
                    accountUserId: viewModel.currentUserAuthId
                )
            }
            .overlay {
                if showFirstLaunchLanguageSelector {
                    FirstLaunchLanguageSelectorOverlay(
                        appLanguageRaw: $appLanguageRaw,
                        detectedLanguageCode: firstLaunchDetectedLanguageCode,
                        onFinished: {
                            showFirstLaunchLanguageSelector = false
                            if let userId = languageSelectorPostAccountCompletionUserId {
                                FanGeoFirstLaunchLanguagePreferences.markPostAccountCreationCompleted(for: userId)
                                languageSelectorPostAccountCompletionUserId = nil
                            }
                            presentStartupGuideIfNeeded()
                        }
                    )
                    .transition(.opacity)
                    .zIndex(2_000)
                }
            }
            .background {
                Color.clear
                    .accessibilityHidden(true)
                    .onChange(of: viewModel.postSignupPresentation) { _, presentation in
                        guard presentation == .discoverWelcomeGuide else { return }
                        presentStartupGuideIfNeeded()
                    }
                    .onChange(of: viewModel.postAccountCreationLanguageSelectorRevision) { _, _ in
                        presentStartupGuideIfNeeded()
                    }
            }
            .sheet(item: $pickupHostPrefillPlace) { place in
                NavigationStack {
                    SettingsPickupGameFormView(
                        viewModel: viewModel,
                        mode: .add,
                        pickupPlacePrefill: place,
                        onCreated: { row in
                            pickupPostCreateInviteGame = row
                        }
                    ) {
                        pickupHostPrefillPlace = nil
                    }
                }
            }
            .sheet(item: $discoverEmptyCreatePickupFormMode) { mode in
                NavigationStack {
                    SettingsPickupGameFormView(
                        viewModel: viewModel,
                        mode: mode,
                        onCreated: { row in
                            pickupPostCreateInviteGame = row
                        }
                    ) {
                        discoverEmptyCreatePickupFormMode = nil
                    }
                }
            }
            .sheet(item: $pickupPostCreateInviteGame) { game in
                PickupGameInviteFriendsSheet(viewModel: viewModel, game: game)
                    .environmentObject(chatViewModel)
            }
    }

    private var discoverScreenWithClusterSheet: some View {
        discoverScreenWithPrimarySheets
            .sheet(item: $clusterForSheet) { cluster in
                discoverClusterVenuesSheet(cluster: cluster)
            }
            .sheet(
                item: $pickupPlaceClusterForSheet,
                onDismiss: openPendingPickupPlaceHostFromClusterIfNeeded
            ) { cluster in
                PickupPlaceClusterSheetView(
                    cluster: cluster,
                    currentUserLocation: viewModel.currentUserLocation,
                    onHostGameHere: hostPickupGameFromPickupPlaceClusterSheet
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
    }

    private var discoverScreenWithPrimarySheets: some View {
        discoverScreenCore
            .sheet(isPresented: Binding(
                get: {
                    showVenueDetails
                        && viewModel.selectedBar != nil
                        && (viewModel.canViewDiscoverDetails() || viewModel.isGuestDiscoverMode)
                },
                set: {
                    if !$0 {
                        showVenueDetails = false
                        venuePreviewDetailEvent = nil
                    }
                }
            )) {
                discoverVenueDetailSheet()
            }
            .sheet(item: Binding(
                get: {
                    guard viewModel.isAuthenticatedForSocialFeatures else { return nil }
                    return fanUpdatesSheetEvent
                },
                set: { fanUpdatesSheetEvent = $0 }
            )) { event in
                VenueEventCommentsSheet(
                    viewModel: viewModel,
                    venueEventID: event.id,
                    title: event.title
                )
            }
            .sheet(item: $predictionSheet) { context in
                VenueEventPredictionSheet(
                    venueEventID: context.venueEventID,
                    teams: context.teams,
                    predictionType: context.predictionType,
                    unavailableMessage: context.unavailableMessage,
                    lockTime: context.lockTime,
                    onSaved: {
                        await viewModel.refreshVenueEventPredictionSummary(eventID: context.venueEventID)
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: Binding(
                get: { showVenueRatingSheet && viewModel.canRateVenues && viewModel.isAuthenticatedForSocialFeatures && viewModel.selectedBar != nil },
                set: { if !$0 { showVenueRatingSheet = false } }
            )) {
                if let bar = viewModel.selectedBar {
                    VenueUserRatingSheet(viewModel: viewModel, bar: bar)
                }
            }
            .sheet(item: $discoverProGameDetailMatch) { match in
                LiveMatchDetailSheet(
                    match: match,
                    viewModel: viewModel,
                    mapBounds: viewModel.currentMapRegionBounds(),
                    showsDiscoverProGameActions: true,
                    onSelectWatchSpot: { bar in
                        discoverProGameDetailMatch = nil
                        withAnimation(.spring()) {
                            viewModel.selectVenueFromDiscoverSearchResult(bar)
                        }
                    },
                    onOpenInSchedule: {
                        let selected = match
                        discoverProGameDetailMatch = nil
                        viewModel.enqueueScheduleProGameNav(match: selected)
                    }
                )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
    }

    private var discoverScreenCore: some View {
        discoverScreenCoreBase
        .alert(
            "FanGeo",
            isPresented: fanFeatureGateAlertBinding
        ) {
            Button("OK", role: .cancel) {
                fanFeatureGateAlertMessage = nil
            }
        } message: {
            Text(fanFeatureGateAlertMessage ?? "")
        }
        .alert(
            L10n.t("venue_business_account_required", languageCode: appLanguageRaw),
            isPresented: $showUnclaimedBusinessAccountRequiredConfirm
        ) {
            Button(L10n.t("venue_claim_continue", languageCode: appLanguageRaw)) {
                if let bar = pendingUnclaimedClaimBar {
                    continueUnclaimedVenueClaimOnboarding(bar: bar)
                }
                pendingUnclaimedClaimBar = nil
            }
            Button(L10n.t("cancel", languageCode: appLanguageRaw), role: .cancel) {
                pendingUnclaimedClaimBar = nil
            }
        } message: {
            Text(L10n.t("venue_business_account_required_message", languageCode: appLanguageRaw))
        }
        .alert(
            L10n.t("venue_claim_this_venue", languageCode: appLanguageRaw),
            isPresented: $showUnclaimedOwnerClaimConfirm
        ) {
            Button(L10n.t("venue_claim_continue", languageCode: appLanguageRaw)) {
                if let bar = pendingUnclaimedClaimBar {
                    Task {
                        _ = await viewModel.submitVenueOwnershipClaimFromVenueDetail(bar: bar)
                    }
                }
                pendingUnclaimedClaimBar = nil
            }
            Button(L10n.t("cancel", languageCode: appLanguageRaw), role: .cancel) {
                pendingUnclaimedClaimBar = nil
            }
        } message: {
            Text(L10n.t("venue_claim_benefits", languageCode: appLanguageRaw))
        }
        .task {
            await handleDiscoverCoreTask()
        }
        .onAppear(perform: handleDiscoverCoreAppear)
        .onChange(of: viewModel.currentUserLocation?.latitude) { _, _ in
            scheduleDiscoverWeatherRefresh(force: false)
        }
        .onChange(of: showDatePicker) { _, isOpen in
            isCalendarOverlayPresented = isOpen
            if !isOpen {
                viewModel.endDiscoverDatePickerGeographicFreeze()
            }
            guard isOpen else { return }
            #if DEBUG
            print(
                "[DiscoverCalendarDotsDebug] discoverDatePickerOpen discoverMapContentMode=\(viewModel.discoverMapContentMode.rawValue) selectedSport=\(viewModel.selectedSport) selectedDate=\(viewModel.selectedDate) bars=\(viewModel.bars.count) mapVisibleBars=\(viewModel.mapVisibleBars.count) venueEventRows=\(viewModel.venueEventRows.count) pickupGamesForDiscoverMap=\(viewModel.pickupGamesForDiscoverMap.count) venueGameCalendarDotDates=\(viewModel.venueGameCalendarDotDates.count) pickupGameCalendarDotDates=\(viewModel.pickupGameCalendarDotDates.count)"
            )
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                discoverMapLocationAuthVersion += 1
                let locationStatus = CLLocationManager().authorizationStatus
                if locationStatus == .authorizedAlways || locationStatus == .authorizedWhenInUse {
                    discoverLocationHint = nil
                }
                scheduleDiscoverWeatherRefresh(force: false)
                if viewModel.discoverMapContentMode == .pickupGames, viewModel.discoverPickupSubMode == .games {
                    Task {
                        await viewModel.refreshPickupGamesForDiscoverMap(
                            force: true,
                            preservePickupCalendarDotDatesCache: true
                        )
                    }
                } else if isPickupPlacesMode {
                    Task {
                        await viewModel.refreshPickupPlacesForDiscoverMap(force: true)
                    }
                }
            }
        }
        .onChange(of: viewModel.selectedDate) { _, _ in
            venuePreviewDetailEvent = nil
            viewModel.pruneSelectionIfNeededAfterFilterChange()
        }
        .onChange(of: viewModel.searchText) { _, _ in
            viewModel.pruneSelectionIfNeededAfterFilterChange()
            viewModel.scheduleDiscoverSearchDebounce()
        }
        .onChange(of: viewModel.mapDisplayMode) { _, _ in
            guard let selectedBar = viewModel.selectedBar else { return }
            let stillVisible = viewModel.mapVisibleBars.contains { $0.id == selectedBar.id }
            if !stillVisible {
                viewModel.clearSelectedEvent()
            }
        }
        .onChange(of: viewModel.selectedBar?.id) { _, _ in
            venuePreviewDetailEvent = nil
        }
        .onChange(of: showVenueDetails) { _, isPresented in
            if isPresented {
                venueDetailOpenStartedAt = UIPerformanceDiagnostics.timestamp()
                let venueId = viewModel.selectedBar?.id.uuidString.lowercased() ?? "nil"
                UIPerformanceDiagnostics.signpost("Venue detail open", "venueId=\(venueId)")
            } else {
                venueDetailOpenStartedAt = nil
            }
        }
        .onChange(of: viewModel.discoverMapContentMode) { oldMode, newMode in
            invalidateDiscoverVenueAnnotationCaches(trigger: "modeSwitch")
            if newMode != .venues {
                mapDisplayModeHintTask?.cancel()
                mapDisplayModeHintText = nil
            }
            if newMode == .pickupGames {
                viewModel.onDiscoverMapBecamePickupGamesFromUserToggle()
            } else if newMode == .venues, oldMode == .pickupGames {
                let requestID = viewModel.beginDiscoverDateChange(to: viewModel.selectedDate)
                #if DEBUG
                print("[DiscoverNarrowRefreshDebug] modeSwitchPickupToVenuesUsingSelectedDayRefresh=true")
                print("[DiscoverNarrowRefreshDebug] skippedBroadLoadGamesOnModeSwitch=true")
                #endif
                viewModel.scheduleDiscoverSelectedDayRefresh(requestID: requestID)
            }
            let anchorMonth = showDatePicker ? discoverCalendarDisplayedMonth : viewModel.selectedDate
            Task { @MainActor in
                await ensureDiscoverDatasetConsistency(trigger: "modeSwitch")
                viewModel.loadDiscoverCalendarDots(around: anchorMonth, reason: "mode_change")
            }
        }
        .onChange(of: viewModel.discoverPickupSubMode) { _, subMode in
            guard viewModel.discoverMapContentMode == .pickupGames else { return }
            invalidateDiscoverVenueAnnotationCaches(trigger: "pickupSubModeSwitch")
            if subMode == .places {
                viewModel.clearPickupMapSelection()
                Task { @MainActor in
                    await ensureDiscoverDatasetConsistency(trigger: "pickupSubModeSwitch")
                }
            } else {
                viewModel.selectedBar = nil
                viewModel.selectedPickupPlaceForMap = nil
                Task { @MainActor in
                    await ensureDiscoverDatasetConsistency(trigger: "pickupSubModeSwitch")
                }
            }
        }
        .onChange(of: discoverAnnotationInvalidationToken) { _, _ in
            guard isDiscoverTabSelected else {
                DebugLogGate.discoverTabPerfVerbose(
                    "[DiscoverPerf] inactive skipped heavy map work reason=annotationInvalidation"
                )
                return
            }
            rebuildDiscoverAnnotationCache(reason: "annotationInvalidation")
        }
        .onChange(of: isDiscoverTabSelected) { _, visible in
            if !visible {
                discoverSearchResultFilter = .all
                viewModel.noteDiscoverTabBecameHidden()
                return
            }
            TabPerf.selectedTab("discover")
            AppPerfDebug.screenLoadStart(tab: "discover", source: "tabVisible")
            presentStartupGuideIfNeeded()
            Task { @MainActor in
                await viewModel.refreshDiscoverBannerAnnouncementForDiscoverTabVisible()
                DebugLogGate.discoverTabPerfVerbose(
                    "[DiscoverPerf] announcement refresh source=DiscoverScreen reason=tabVisible"
                )
                if await viewModel.consumePendingDiscoverFocusVenue(source: "discoverTabVisible") {
                    showVenueDetails = true
                }
                await Task.yield()
                TabPerf.tabSwitchRendered(tab: "discover")
                AppPerfDebug.deferredWork(tab: "discover", work: "datasetConsistency", source: "tabVisible")
                await ensureDiscoverDatasetConsistency(trigger: "tabVisible")
            }
        }
        .onChange(of: viewModel.pendingFollowingMapVenueID) { _, id in
            guard id != nil else { return }
            Task {
                await viewModel.consumeFollowingVenueNavigationIfPending()
            }
        }
        .onChange(of: viewModel.discoverFocusVenueId) { _, venueId in
            guard venueId != nil else { return }
            Task { @MainActor in
                if await viewModel.consumePendingDiscoverFocusVenue(source: "discoverFocusVenue") {
                    showVenueDetails = true
                }
            }
        }
        .onChange(of: viewModel.discoverAuthGateActive) { wasActive, isActive in
            viewModel.logDiscoverAuthGateDebug()
            if !isActive {
                showVenueDetails = false
                showVenueRatingSheet = false
                fanUpdatesSheetEvent = nil
                pendingResumeVenueIDAfterLogin = nil
            } else {
                resumeDiscoverSelectionAfterFanLoginIfNeeded(wasActive: wasActive, isActive: isActive)
            }
        }
    }

    private var discoverScreenCoreBase: AnyView {
        AnyView(
            GeometryReader { layoutGeo in
                discoverScreenMapLayout(
                    layoutWidth: layoutGeo.size.width,
                    layoutHeight: layoutGeo.size.height
                )
            }
        )
    }

    private func discoverScreenMapLayout(layoutWidth: CGFloat, layoutHeight: CGFloat) -> some View {
        ZStack(alignment: .top) {
            mapLayer
        }
        .overlay(alignment: .top) {
            discoverFixedTopOverlay(layoutWidth: layoutWidth, layoutHeight: layoutHeight)
        }
        .overlay(alignment: .bottom) {
            discoverFixedBottomOverlay(layoutWidth: layoutWidth)
                .opacity(showDatePicker ? 0.36 : 1)
                .blur(radius: showDatePicker ? 1.25 : 0)
                .allowsHitTesting(!showDatePicker)
                .animation(.easeInOut(duration: 0.24), value: showDatePicker)
        }
        .overlay {
            if showDatePicker {
                discoverMapDatePickerOverlay
            }
        }
        .onAppear {
            discoverLogLayoutDebug(layoutWidth: layoutWidth)
        }
        .onChange(of: viewModel.announcementAudienceSelectionKey) { _, _ in
            viewModel.applyDiscoverBannerSelectionFromCache()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            updateDiscoverSearchKeyboardOverlap(from: notification, layoutHeight: layoutHeight)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            if discoverSearchKeyboardBottomOverlap != 0 {
                discoverSearchKeyboardBottomOverlap = 0
            }
        }
        .onChange(of: isSearchFocused) { _, focused in
            if !focused, discoverSearchKeyboardBottomOverlap != 0 {
                discoverSearchKeyboardBottomOverlap = 0
            }
        }
    }

    private func updateDiscoverSearchKeyboardOverlap(
        from notification: Notification,
        layoutHeight: CGFloat
    ) {
        guard isSearchFocused else {
            if discoverSearchKeyboardBottomOverlap != 0 {
                discoverSearchKeyboardBottomOverlap = 0
            }
            return
        }
        guard
            let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else { return }

        // Convert keyboard frame into an overlap against the Discover layout height.
        // Prefer the key window / active scene screen so Stage Manager and multi-scene stay accurate.
        let overlap: CGFloat
        if let window = discoverSearchKeyWindow() {
            let keyboardInWindow = window.convert(frame, from: nil)
            overlap = max(0, window.bounds.maxY - keyboardInWindow.minY)
        } else {
            let screenHeight = max(layoutHeight, discoverSearchSceneScreenBounds().height)
            overlap = max(0, screenHeight - frame.minY)
        }

        // Ignore tiny predictive-bar jitter.
        let normalized = overlap < 8 ? 0 : overlap
        if abs(normalized - discoverSearchKeyboardBottomOverlap) > 0.5 {
            discoverSearchKeyboardBottomOverlap = normalized
        }
    }

    private func discoverSearchKeyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    /// Screen bounds from the active/foreground window scene — never the deprecated global main screen API.
    private func discoverSearchSceneScreenBounds() -> CGRect {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let active = scenes.first(where: { $0.activationState == .foregroundActive }) {
            return active.screen.bounds
        }
        if let foreground = scenes.first(where: {
            $0.activationState == .foregroundInactive || $0.activationState == .foregroundActive
        }) {
            return foreground.screen.bounds
        }
        if let anyScene = scenes.first {
            return anyScene.screen.bounds
        }
        // Last resort: empty bounds so callers fall back to layoutHeight via max(...).
        return CGRect(x: 0, y: 0, width: 0, height: 0)
    }

    private var fanFeatureGateAlertBinding: Binding<Bool> {
        Binding(
            get: { fanFeatureGateAlertMessage != nil },
            set: { isPresented in
                if !isPresented {
                    fanFeatureGateAlertMessage = nil
                }
            }
        )
    }

    private func handleDiscoverCoreTask() async {
        viewModel.reloadVenueUserRatingsFromStorage()
        viewModel.logDiscoverAuthGateDebug()
        await viewModel.ensureBusinessOwnerSessionFlagsIfPossible(context: "discover_enter")
        viewModel.logBusinessOwnerSessionFlags(context: "discover_enter")
    }

    private func handleDiscoverCoreAppear() {
        isCalendarOverlayPresented = showDatePicker
        viewModel.clampDiscoverMapSelectedDateToMinimumCalendarDayIfNeeded()
        discoverLogRedesignDebug()
        scheduleDiscoverWeatherRefresh(force: true)
        presentStartupGuideIfNeeded()
        Task {
            if isDiscoverTabSelected {
                await viewModel.refreshDiscoverBannerAnnouncementForDiscoverTabVisible()
                DebugLogGate.discoverTabPerfVerbose(
                    "[DiscoverPerf] announcement refresh source=DiscoverScreen reason=appear"
                )
            }
            await viewModel.ensureBusinessOwnerSessionFlagsIfPossible(context: "discover_on_appear")
            viewModel.logBusinessOwnerSessionFlags(context: "discover_on_appear")
            await Task.yield()
            await ensureDiscoverDatasetConsistency(trigger: "appear")
        }
    }

    @ViewBuilder
    private func discoverClusterVenuesSheet(cluster: VenueCluster) -> some View {
        let rows = sortedClusterBarsForSheet(cluster.bars)
#if DEBUG
        let uniqueIds = Set(rows.map(\.id))
        let _: Void = {
            print("[VenuePreviewDebug] present source=cluster count=\(cluster.count)")
            print("[VenuePreviewDebug] render count=\(rows.count) uniqueIds=\(uniqueIds.count)")
            print("[VenuePreviewDebug] invalidDuplicateIds=\(max(0, rows.count - uniqueIds.count))")
        }()
#endif
        NavigationStack {
            List {
                // Leaf rows only — never embeds `venuePreviewCard` / Discover overlay.
                ForEach(rows, id: \.id) { bar in
                    let displayClass = venuePinDisplayClass(for: bar)
                    let safeName = bar.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    Button {
                        clusterForSheet = nil
                        withAnimation(.spring()) {
                            viewModel.centerMap(on: bar)
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(safeName.isEmpty ? "Venue" : safeName)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.85)
                                Text(bar.address)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            // Claimed + Business Pro both show "Business"; Pro keeps gold pill + row chrome.
                            venueClusterSheetStatusPill(displayClass)
                                .padding(.top, 1)
                                .accessibilityLabel(
                                    displayClass == .unclaimedCommunity
                                        ? L10n.t("venue_unclaimed_business", languageCode: appLanguageRaw)
                                        : venueClusterSheetStatusTitle(displayClass)
                                )
                        }
                        .padding(.vertical, 2)
                        .background {
                            if displayClass == .proVenue {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color(red: 1.0, green: 0.82, blue: 0.30).opacity(colorScheme == .dark ? 0.10 : 0.07))
                                    .padding(.horizontal, -8)
                                    .padding(.vertical, -5)
                            }
                        }
                    }
                    .listRowBackground(clusterSheetRowBackground(displayClass: displayClass))
                    .onAppear {
                        logVenueClusterSheetDebug(bar: bar, displayClass: displayClass)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .fanGeoScreenBackground()
            .navigationTitle("\(rows.count) venues")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        clusterForSheet = nil
                    }
                }
            }
        }
        .fanGeoScreenBackground()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// Discover date chip opens this overlay (not a sheet) so the map stays visible—no UIKit sheet white chrome or Calendar tab behind it.
    private var discoverMapDatePickerOverlay: some View {
        ZStack {
            Color.black.opacity(0.055)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissDiscoverDatePicker()
                }

            VStack {
                Spacer(minLength: 0)
                LiquidGlassCalendarPicker(
                    events: viewModel.events,
                    bars: viewModel.bars,
                    useVisibleMapRegionOnly: viewModel.calendarUsesVisibleMapRegionOnly,
                    eventDotDates: viewModel.discoverMapContentMode == .venues
                        ? viewModel.venueGameCalendarDotDates
                        : viewModel.pickupGameCalendarDotDates,
                    dotsLoading: viewModel.discoverMapContentMode == .venues
                        ? viewModel.isLoadingVenueCalendarDots
                        : viewModel.isLoadingPickupCalendarDots,
                    dotStatusText: viewModel.calendarDotStatusText,
                    selectedDate: Binding(
                        get: { discoverDatePickerSelection ?? viewModel.selectedDate },
                        set: { discoverDatePickerSelection = $0 }
                    ),
                    minimumSelectableDay: Calendar.current.startOfDay(for: Date()),
                    chrome: .discoverMap,
                    calendarDotPalette: viewModel.discoverMapContentMode == .venues ? .venueGames : .pickupGames,
                    onDone: {
                        applyDiscoverDatePickerSelection()
                    },
                    onDisplayedMonthChange: { month in
                        let cal = Calendar.current
                        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: month)) ?? month
                        // Skip duplicate load when openDiscoverDatePicker already started the same month.
                        if cal.isDate(monthStart, equalTo: discoverCalendarDisplayedMonth, toGranularity: .month),
                           viewModel.isLoadingPickupCalendarDots
                            || viewModel.isLoadingVenueCalendarDots
                            || !viewModel.pickupGameCalendarDotDates.isEmpty
                            || !viewModel.venueGameCalendarDotDates.isEmpty {
                            discoverCalendarDisplayedMonth = monthStart
                            return
                        }
                        discoverCalendarDisplayedMonth = monthStart
                        Task { @MainActor in
                            viewModel.loadDiscoverCalendarDots(around: monthStart, reason: "month_change")
                        }
                    }
                )
                .padding(.horizontal, 8)
                .padding(.bottom, 116)
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.38 : 0.18), radius: 28, y: 16)
                .shadow(color: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.08 : 0.04), radius: 16, y: 4)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .center)))
        .zIndex(900)
    }

    private func resumeDiscoverSelectionAfterFanLoginIfNeeded(wasActive: Bool, isActive: Bool) {
        guard !wasActive, isActive, viewModel.isAuthenticatedForSocialFeatures, let venueID = pendingResumeVenueIDAfterLogin else { return }
        pendingResumeVenueIDAfterLogin = nil
        let fromBars = viewModel.bars.first(where: { $0.id == venueID })
        let fromFiltered = viewModel.filteredBars.first(where: { $0.id == venueID })
        guard let bar = fromBars ?? fromFiltered else { return }
        withAnimation(.spring()) {
            viewModel.selectVenueForPreview(bar, source: "resumeAfterFanLogin")
        }
    }

    @ViewBuilder
    private func discoverVenueDetailSheet() -> some View {
        if let selectedBar = viewModel.selectedBar {
            let claimStatus = viewModel.venueOwnershipClaimStatus(for: selectedBar)
            let showsBusinessOwnershipSection = viewModel.shouldShowVenueOwnershipClaimSection(for: selectedBar)
            let selectedDayGames = viewModel.selectedDayEventsForMap(selectedBar)
            let selectedVenueEvent = selectedEventForVenue(gamesToday: selectedDayGames)
            let ratingCount = viewModel.reviewCountDisplay(for: selectedBar)
            let supportedSports = venueSupportedSports(from: selectedDayGames)
            let displaySport = venueSportLabel(sportsSupported: supportedSports)
            let isBusinessConfirmed = venueIsBusinessConfirmed(bar: selectedBar, claimStatus: claimStatus)
            let effectiveBusinessId = viewModel.effectiveBusinessIdForVenueChat(for: selectedBar)
            let openVenueChatAction: (() async -> Void)? = {
                guard effectiveBusinessId != nil else { return nil }
                return { await openVenueChatFromDetail(for: selectedBar) }
            }()
            let liveEnergy = selectedVenueEvent.map {
                viewModel.liveEnergy(for: selectedBar, event: $0, friendUserIDs: acceptedFriendUserIDs)
            } ?? viewModel.strongestLiveEnergy(
                for: selectedBar,
                events: selectedDayGames,
                friendUserIDs: acceptedFriendUserIDs
            )
            VenueDetailView(
                bar: selectedBar,
                selectedEvent: selectedVenueEvent,
                isFavorite: viewModel.canFavoriteVenues && viewModel.favoriteVenueIDs.contains(selectedBar.id),
                goingCount: viewModel.displayedGoingCount(for: selectedBar),
                liveEnergy: liveEnergy,
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
                        showVenueDetails = false
                        showVenueRatingSheet = true
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
                onClaimThisBusiness: discoverVenueClaimAction(for: selectedBar),
                showsBusinessOwnershipSection: showsBusinessOwnershipSection,
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
                    presentFanUpdatesSheet(venueEventID: id)
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
                showsVenueReportAction: viewModel.isAuthenticatedForSocialFeatures && !viewModel.isGuestDiscoverMode,
                onOpenVenueChat: openVenueChatAction,
                effectiveBusinessId: effectiveBusinessId,
                showsUnclaimedBusinessCallout: selectedBar.isUnclaimedCommunityVenue && !isBusinessConfirmed,
                onBeginUnclaimedVenueClaim: {
                    requestUnclaimedVenueClaim(for: selectedBar)
                },
                unclaimedSocialProofMetrics: (selectedBar.isUnclaimedCommunityVenue && !isBusinessConfirmed)
                    ? unclaimedVenueSocialProofMetrics(for: selectedBar, gamesToday: selectedDayGames)
                    : nil
            )
            .onAppear {
                if let startedAt = venueDetailOpenStartedAt {
                    let ms = UIPerformanceDiagnostics.elapsedMs(since: startedAt)
                    UIPerformanceDiagnostics.log("venueDetailOpen ms=\(UIPerformanceDiagnostics.formattedMs(ms)) venueId=\(selectedBar.id)")
                }
            }
            .task {
                await viewModel.refreshApprovedVenueOwnershipState(for: selectedBar)
                await viewModel.ensureBusinessOwnerSessionFlagsIfPossible(context: "venue_detail_open")
                viewModel.logBusinessOwnerSessionFlags(context: "venue_detail_open")
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
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
            showVenueDetails = false
        case .needsVenuePicker:
            fanFeatureGateAlertMessage = "Choose a venue to continue."
        case .informational(let message):
            fanFeatureGateAlertMessage = message
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

    private func selectedEventForVenue(gamesToday: [SportsEvent]) -> SportsEvent? {
        guard let selectedEvent = viewModel.selectedEvent else {
            if gamesToday.isEmpty, let selectedBar = viewModel.selectedBar {
                logVenueGameCardCrashGuard(reason: "selectedVenueEventNilNoGames", venue: selectedBar, event: nil)
            }
            return nil
        }
        let match = gamesToday.first {
            $0.title == selectedEvent.title &&
            $0.sport == selectedEvent.sport &&
            Calendar.current.isDate($0.date, inSameDayAs: selectedEvent.date)
        }
        if match == nil, let selectedBar = viewModel.selectedBar {
            logVenueGameCardCrashGuard(reason: "selectedVenueEventNotInVenueGames", venue: selectedBar, event: selectedEvent)
        }
        return match
    }

    private func visibleVenuePreviewEventsForSocialPrefetch(
        bar: BarVenue,
        gamesToday: [SportsEvent],
        selectedVenueEvent: SportsEvent?
    ) -> [SportsEvent] {
        if let selectedVenueEvent {
            return [selectedVenueEvent]
        }
        if gamesToday.isEmpty {
            logVenueGameCardCrashGuard(reason: "socialPrefetchEmptyGames", venue: bar, event: nil)
        }
        return Array(gamesToday.prefix(12))
    }

    private func visibleVenuePreviewSocialPrefetchKey(bar: BarVenue, events: [SportsEvent]) -> String {
        let eventKey = events
            .map { "\($0.id)|\($0.title)|\(Int($0.date.timeIntervalSince1970))" }
            .joined(separator: ",")
        return "\(bar.id.uuidString.lowercased())|\(viewModel.selectedSport)|\(eventKey)"
    }

    private func prefetchVisibleVenueSocialData(bar: BarVenue, events: [SportsEvent]) async {
        guard !events.isEmpty else {
            viewModel.prefetchVisibleDiscoverSocialData(eventIDs: [], predictionEventIDs: [])
            return
        }

        var eventIDs: [UUID] = []
        var predictionEventIDs: [UUID] = []
        for event in events {
            let gameTitle = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let venueEventID = await viewModel.venueEventID(for: bar, gameTitle: gameTitle, on: event.date) else { continue }
            eventIDs.append(venueEventID)
            let predictionVisibility = venuePredictionVisibility(
                bar: bar,
                event: event,
                venueEventID: venueEventID
            )
            if predictionVisibility.shouldRender, let predictionEventID = predictionVisibility.eventID {
                predictionEventIDs.append(predictionEventID)
            }
        }
        viewModel.prefetchVisibleDiscoverSocialData(eventIDs: eventIDs, predictionEventIDs: predictionEventIDs)
    }

    private func discoverVenueClaimAction(for bar: BarVenue) -> ((BarVenue) async -> String?)? {
        guard viewModel.canSubmitVenueOwnershipClaim(for: bar) else { return nil }
        return { venue in
            await viewModel.submitVenueOwnershipClaimFromVenueDetail(bar: venue)
        }
    }

    private func requestUnclaimedVenueClaim(for bar: BarVenue) {
        guard bar.isUnclaimedCommunityVenue else { return }
        pendingUnclaimedClaimBar = bar
        if viewModel.hasAuthenticatedVenueOwnerSession,
           viewModel.canSubmitVenueOwnershipClaim(for: bar) {
            showUnclaimedOwnerClaimConfirm = true
        } else {
            showUnclaimedBusinessAccountRequiredConfirm = true
        }
    }

    private func continueUnclaimedVenueClaimOnboarding(bar: BarVenue) {
        viewModel.beginVenueClaimFromDiscover(bar: bar)
        closeVenuePreview()
        clusterForSheet = nil
    }

    /// Returns true when center or zoom changed enough to warrant another venue fetch.
    private func mapVenueRegionIsMeaningfullyDifferent(from previous: MKCoordinateRegion, to new: MKCoordinateRegion) -> Bool {
        mapVenueReloadDelta(from: previous, to: new).isMeaningful
    }

    /// True when MapKit re-reports a region that differs only by float / sub-pixel settle noise.
    /// Thresholds are far below venue reload (4 mi / 20% span) and any intentional pan or zoom.
    private func discoverCameraRegionIsEffectivelyIdentical(_ previous: MKCoordinateRegion, _ reported: MKCoordinateRegion) -> Bool {
        let centerMeters = MapViewModel.distanceMeters(from: previous.center, to: reported.center)
        let prevLatSpan = max(previous.span.latitudeDelta, 1e-9)
        let prevLonSpan = max(previous.span.longitudeDelta, 1e-9)
        let spanLatRatio = abs(previous.span.latitudeDelta - reported.span.latitudeDelta) / prevLatSpan
        let spanLonRatio = abs(previous.span.longitudeDelta - reported.span.longitudeDelta) / prevLonSpan
        return centerMeters < 3.0 && spanLatRatio < 0.0005 && spanLonRatio < 0.0005
    }

    private func mapVenueReloadDelta(from previous: MKCoordinateRegion, to new: MKCoordinateRegion) -> (
        isMeaningful: Bool,
        distanceMovedMiles: Double,
        boundsChangedSignificantly: Bool
    ) {
        let prevLatSpan = max(previous.span.latitudeDelta, 1e-9)
        let prevLonSpan = max(previous.span.longitudeDelta, 1e-9)
        let spanLatRatio = abs(previous.span.latitudeDelta - new.span.latitudeDelta) / prevLatSpan
        let spanLonRatio = abs(previous.span.longitudeDelta - new.span.longitudeDelta) / prevLonSpan
        let distanceMeters = MapViewModel.distanceMeters(from: previous.center, to: new.center)
        let distanceMovedMiles = distanceMeters / 1609.344
        let centerMovedMeaningfully = distanceMovedMiles >= 4.0
        let boundsChangedSignificantly = spanLatRatio > 0.20 || spanLonRatio > 0.20
        return (
            centerMovedMeaningfully || boundsChangedSignificantly,
            distanceMovedMiles,
            boundsChangedSignificantly
        )
    }

    private func mapVenueRegionJumpIsMajor(
        distanceMovedMiles: Double,
        boundsChangedSignificantly: Bool
    ) -> Bool {
        distanceMovedMiles >= 50 || (distanceMovedMiles >= 15 && boundsChangedSignificantly)
    }

    private func logDiscoverRegionJump(
        oldRegion: MKCoordinateRegion?,
        newRegion: MKCoordinateRegion,
        distanceMovedMiles: Double?,
        triggeredFastBoundsFetch: Bool
    ) {
#if DEBUG
        let oldCenter = oldRegion.map {
            "\($0.center.latitude),\($0.center.longitude)"
        } ?? "nil"
        let newCenter = "\(newRegion.center.latitude),\(newRegion.center.longitude)"
        let distance = distanceMovedMiles.map { String(format: "%.2f", $0) } ?? "nil"
        print("[DiscoverRegionJumpDebug] oldCenter=\(oldCenter)")
        print("[DiscoverRegionJumpDebug] newCenter=\(newCenter)")
        print("[DiscoverRegionJumpDebug] distanceMiles=\(distance)")
        print("[DiscoverRegionJumpDebug] triggeredFastBoundsFetch=\(triggeredFastBoundsFetch)")
#endif
    }

    private func discoverReloadConsistencyModeLabel() -> String {
        if viewModel.discoverMapContentMode == .pickupGames {
            return "\(viewModel.discoverMapContentMode.rawValue).\(viewModel.discoverPickupSubMode.rawValue)"
        }
        return viewModel.discoverMapContentMode.rawValue
    }

    private func discoverReloadConsistencyBoundsDescription() -> String {
        guard let b = viewModel.currentMapRegionBounds() else { return "nil" }
        return String(
            format: "%.5f...%.5f,%.5f...%.5f",
            b.minLat,
            b.maxLat,
            b.minLon,
            b.maxLon
        )
    }

    private func invalidateDiscoverVenueAnnotationCaches(trigger: String) {
        viewModel.discoverClusteredBarsCacheKey = nil
        viewModel.discoverClusteredBarsCache = nil
        discoverAnnotationCache = .empty
#if DEBUG
        print("[VenueReloadConsistencyDebug] trigger=\(trigger)")
        print("[VenueReloadConsistencyDebug] cacheInvalidated=true")
#endif
    }

    private func logVenueReloadConsistency(
        trigger: String,
        barsBefore: Int,
        rowsFetched: Int?,
        barsAfter: Int?,
        annotationsBefore: Int,
        annotationsAfter: Int?,
        reloadStarted: Bool,
        skippedReason: String?
    ) {
#if DEBUG
        print("[VenueReloadConsistencyDebug] trigger=\(trigger)")
        print("[VenueReloadConsistencyDebug] mode=\(discoverReloadConsistencyModeLabel())")
        print("[VenueReloadConsistencyDebug] bounds=\(discoverReloadConsistencyBoundsDescription())")
        print("[VenueReloadConsistencyDebug] barsBefore=\(barsBefore)")
        print("[VenueReloadConsistencyDebug] rowsFetched=\(rowsFetched.map { "\($0)" } ?? "nil")")
        print("[VenueReloadConsistencyDebug] barsAfter=\(barsAfter.map { "\($0)" } ?? "nil")")
        print("[VenueReloadConsistencyDebug] annotationsBefore=\(annotationsBefore)")
        print("[VenueReloadConsistencyDebug] annotationsAfter=\(annotationsAfter.map { "\($0)" } ?? "nil")")
        print("[VenueReloadConsistencyDebug] reloadStarted=\(reloadStarted)")
        print("[VenueReloadConsistencyDebug] reloadSkippedReason=\(skippedReason ?? "none")")
#endif
    }

    @MainActor
    private func ensureDiscoverDatasetConsistency(
        trigger: String,
        forceCurrentModeReload: Bool = false,
        fastRegionJump: Bool = false,
        regionOverride: MKCoordinateRegion? = nil
    ) async {
        guard isDiscoverTabSelected else {
            DebugLogGate.discoverTabPerfVerbose(
                "[DiscoverPerf] inactive skipped heavy map work reason=ensureDiscoverDatasetConsistency trigger=\(trigger)"
            )
            return
        }
        DebugLogGate.discoverTabPerfVerbose(
            "[DiscoverPerf] active running consistency check trigger=\(trigger)"
        )
        if isPassiveDiscoverTabConsistencyTrigger(trigger),
           !forceCurrentModeReload,
           let last = lastDiscoverTabConsistencyAt,
           Date().timeIntervalSince(last) < Self.discoverTabConsistencyTTL {
            TabPerf.refreshSkipped(name: "discoverDatasetConsistency", reason: "freshCache")
            rebuildDiscoverAnnotationCache(reason: "venueReloadConsistency_\(trigger)_cached")
            return
        }

        let trackPassiveTabConsistency = isPassiveDiscoverTabConsistencyTrigger(trigger) && !forceCurrentModeReload
        defer {
            if trackPassiveTabConsistency {
                lastDiscoverTabConsistencyAt = Date()
            }
        }

        let barsBefore = viewModel.bars.count
        let annotationsBefore = discoverAnnotationCache.counts.renderedCount(mode: viewModel.discoverMapContentMode)
        let region = regionOverride ?? viewModel.cameraPosition.region

        rebuildDiscoverAnnotationCache(reason: "venueReloadConsistency_\(trigger)")
        let annotationsAfterRebuild = discoverAnnotationCache.counts.renderedCount(mode: viewModel.discoverMapContentMode)

        switch viewModel.discoverMapContentMode {
        case .venues:
            let visibleBars = viewModel.visibleBarCountInCurrentMapRegion()
            let regionDelta = lastMapVenueReloadRegion.flatMap { previous -> (isMeaningful: Bool, distanceMovedMiles: Double, boundsChangedSignificantly: Bool)? in
                guard let region else { return nil }
                return mapVenueReloadDelta(from: previous, to: region)
            }
            let hasLoadedCurrentBounds = regionDelta?.isMeaningful == false
            let shouldReload = forceCurrentModeReload
                || (!hasLoadedCurrentBounds && (regionDelta?.isMeaningful == true))
                || (!hasLoadedCurrentBounds && viewModel.bars.isEmpty)
                || (!hasLoadedCurrentBounds && annotationsAfterRebuild == 0 && visibleBars == 0)

            guard shouldReload else {
                if lastMapVenueReloadRegion == nil, annotationsAfterRebuild > 0, let region {
                    lastMapVenueReloadRegion = region
                }
                logVenueReloadConsistency(
                    trigger: trigger,
                    barsBefore: barsBefore,
                    rowsFetched: nil,
                    barsAfter: viewModel.bars.count,
                    annotationsBefore: annotationsBefore,
                    annotationsAfter: annotationsAfterRebuild,
                    reloadStarted: false,
                    skippedReason: hasLoadedCurrentBounds ? "currentBoundsFresh" : "cachedAnnotationsValid"
                )
                return
            }

            logVenueReloadConsistency(
                trigger: trigger,
                barsBefore: barsBefore,
                rowsFetched: nil,
                barsAfter: nil,
                annotationsBefore: annotationsBefore,
                annotationsAfter: annotationsAfterRebuild,
                reloadStarted: true,
                skippedReason: nil
            )
            await viewModel.loadVenuesFromSupabase(
                forceRefresh: forceCurrentModeReload,
                fastRegionJump: fastRegionJump
            )
            if let region {
                lastMapVenueReloadRegion = region
            }
            invalidateDiscoverVenueAnnotationCaches(trigger: "\(trigger).postReload")
            rebuildDiscoverAnnotationCache(reason: "venueReloadConsistency_\(trigger)_postReload")
            logVenueReloadConsistency(
                trigger: trigger,
                barsBefore: barsBefore,
                rowsFetched: viewModel.discoverCurrentVisibleVenueRows.count,
                barsAfter: viewModel.bars.count,
                annotationsBefore: annotationsBefore,
                annotationsAfter: discoverAnnotationCache.counts.venue,
                reloadStarted: true,
                skippedReason: nil
            )

        case .pickupGames:
            defer {
                if trigger == "citySearch" {
                    viewModel.pendingCitySearchVenueDebugContext = nil
                }
            }
            if viewModel.discoverPickupSubMode == .places {
                let visiblePlaces = viewModel.discoverVisiblePickupPlaceCount
                let shouldReload = forceCurrentModeReload || (visiblePlaces == 0 && !viewModel.isLoadingPickupPlacesForMap)
                guard shouldReload else {
                    logVenueReloadConsistency(
                        trigger: trigger,
                        barsBefore: barsBefore,
                        rowsFetched: nil,
                        barsAfter: viewModel.bars.count,
                        annotationsBefore: annotationsBefore,
                        annotationsAfter: annotationsAfterRebuild,
                        reloadStarted: false,
                        skippedReason: "pickupPlacesCacheValid"
                    )
                    return
                }
                logVenueReloadConsistency(
                    trigger: trigger,
                    barsBefore: barsBefore,
                    rowsFetched: nil,
                    barsAfter: nil,
                    annotationsBefore: annotationsBefore,
                    annotationsAfter: annotationsAfterRebuild,
                    reloadStarted: true,
                    skippedReason: nil
                )
                await viewModel.refreshPickupPlacesForDiscoverMap(force: forceCurrentModeReload || viewModel.pickupPlacesForDiscoverMap.isEmpty)
                rebuildDiscoverAnnotationCache(reason: "venueReloadConsistency_\(trigger)_pickupPlaces")
                logVenueReloadConsistency(
                    trigger: trigger,
                    barsBefore: barsBefore,
                    rowsFetched: viewModel.pickupPlacesForDiscoverMap.count,
                    barsAfter: viewModel.bars.count,
                    annotationsBefore: annotationsBefore,
                    annotationsAfter: discoverAnnotationCache.counts.pickupPlaces,
                    reloadStarted: true,
                    skippedReason: nil
                )
            } else {
                let visibleGames = viewModel.pickupGamesVisibleAsMapPins(for: viewModel.currentMapRegionBounds()).count
                // Meaningful map pans always attempt a viewport-keyed refresh (force=false → TTL/cache).
                // Do not require visibleGames==0; prior viewport rows may still pin-filter as non-empty.
                let isMapViewportConsistency = trigger == "mapRegionChanged"
                let shouldReload = forceCurrentModeReload
                    || isMapViewportConsistency
                    || (visibleGames == 0 && !viewModel.isLoadingPickupGamesForMap)
                guard shouldReload else {
                    logVenueReloadConsistency(
                        trigger: trigger,
                        barsBefore: barsBefore,
                        rowsFetched: nil,
                        barsAfter: viewModel.bars.count,
                        annotationsBefore: annotationsBefore,
                        annotationsAfter: annotationsAfterRebuild,
                        reloadStarted: false,
                        skippedReason: "pickupGamesCacheValid"
                    )
                    return
                }
                logVenueReloadConsistency(
                    trigger: trigger,
                    barsBefore: barsBefore,
                    rowsFetched: nil,
                    barsAfter: nil,
                    annotationsBefore: annotationsBefore,
                    annotationsAfter: annotationsAfterRebuild,
                    reloadStarted: true,
                    skippedReason: nil
                )
                await viewModel.refreshPickupGamesForDiscoverMap(
                    force: forceCurrentModeReload,
                    preservePickupCalendarDotDatesCache: true
                )
                viewModel.scheduleDiscoverVenueCalendarDotRefreshAfterMapViewportChange()
                rebuildDiscoverAnnotationCache(reason: "venueReloadConsistency_\(trigger)_pickupGames")
                logVenueReloadConsistency(
                    trigger: trigger,
                    barsBefore: barsBefore,
                    rowsFetched: viewModel.pickupGamesForDiscoverMap.count,
                    barsAfter: viewModel.bars.count,
                    annotationsBefore: annotationsBefore,
                    annotationsAfter: discoverAnnotationCache.counts.pickupGames,
                    reloadStarted: true,
                    skippedReason: nil
                )
            }
        }
    }

    private enum VenuePinDisplayState {
        case gameScheduled
        case noGameScheduled
    }

    private enum VenuePinDisplayClass: String {
        case unclaimedCommunity
        case claimedCommunity
        case businessVenue
        case proVenue
    }

    private enum ClusterDisplayState {
        case gameScheduled
        case noGameScheduled
    }

    private func mapDepthScale(isSelected: Bool, isNearby: Bool = true) -> CGFloat {
        if isSelected { return 1.10 }
        return isNearby ? 1.02 : 0.96
    }

    private func logMapDepthMarker(id: String, scale: CGFloat, selected: Bool) {
#if DEBUG
        print("[MapDepthDebug] selectedMarker=\(selected ? id : "nil")")
        print("[MapDepthDebug] markerScale=\(String(format: "%.2f", Double(scale)))")
        print("[MapDepthDebug] markerShadowApplied=true")
#endif
    }

    private func logMapDepthPulse(isSelected: Bool, id: String) {
#if DEBUG
        print(isSelected ? "[MapDepthDebug] pulseStarted=\(id)" : "[MapDepthDebug] pulseStopped=\(id)")
#endif
    }

    private func logMapDepthCluster(id: String) {
#if DEBUG
        print("[MapDepthDebug] clusterStyled=\(id)")
        print("[MapDepthDebug] markerShadowApplied=true")
#endif
    }

    private func mapDepthPulseRing(tint: Color) -> some View {
        MapDepthPulseRing(tint: tint)
    }

    private func mapDepthStyledMarker<Content: View>(
        id: String,
        isSelected: Bool,
        tint: Color = FGColor.accentBlue,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let scale = mapDepthScale(isSelected: isSelected)
        return ZStack {
            if isSelected {
                mapDepthPulseRing(tint: tint)
                    .frame(width: 58, height: 58)
            }
            content()
        }
        .scaleEffect(scale)
        .shadow(color: .black.opacity(isSelected ? 0.22 : 0.13), radius: isSelected ? 8 : 5, y: isSelected ? 5 : 3)
        .zIndex(isSelected ? 20 : 1)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isSelected)
        .onAppear {
            logMapDepthMarker(id: id, scale: scale, selected: isSelected)
            logMapDepthPulse(isSelected: isSelected, id: id)
        }
        .onChange(of: isSelected) { _, selected in
            logMapDepthMarker(id: id, scale: mapDepthScale(isSelected: selected), selected: selected)
            logMapDepthPulse(isSelected: selected, id: id)
        }
    }

    private func mapDepthStyledCluster<Content: View>(
        id: String,
        tint: Color,
        isActive: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let shouldAnimate = isDiscoverTabSelected && isActive
        return content()
            .background {
                Circle()
                    .fill(tint.opacity(isActive ? 0.10 : 0.06))
                    .scaleEffect(isActive ? 1.18 : 1.10)
                    .blur(radius: isActive ? 3 : 0)
                    .allowsHitTesting(false)
            }
            .shadow(color: tint.opacity(isActive ? 0.16 : 0.08), radius: isActive ? 8 : 5, y: 3)
            .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
            .transition(.scale(scale: 0.96).combined(with: .opacity))
            .animation(shouldAnimate ? .spring(response: 0.34, dampingFraction: 0.82) : nil, value: id)
            .onAppear { logMapDepthCluster(id: id) }
    }

    private func venuePinDisplayClass(for bar: BarVenue) -> VenuePinDisplayClass {
        if venueIsProForPinDisplay(bar) {
            return .proVenue
        }

        let origin = bar.originType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if origin == "community" {
            return bar.hasBusinessVerifiedFeatures ? .claimedCommunity : .unclaimedCommunity
        }
        if origin == "business" || bar.businessId != nil || bar.hasBusinessVerifiedFeatures {
            return .businessVenue
        }
        return .businessVenue
    }

    private func venueClusterDisplayClass(for cluster: VenueCluster) -> VenuePinDisplayClass {
        let classes = cluster.bars.map { venuePinDisplayClass(for: $0) }
        if classes.contains(.proVenue) { return .proVenue }
        if classes.contains(.businessVenue) { return .businessVenue }
        if classes.contains(.claimedCommunity) { return .claimedCommunity }
        return .unclaimedCommunity
    }

    private func venuePinDisplayPriority(_ displayClass: VenuePinDisplayClass) -> Int {
        switch displayClass {
        case .proVenue:
            return 0
        case .businessVenue, .claimedCommunity:
            return 1
        case .unclaimedCommunity:
            return 2
        }
    }

    private func sortedClusterBarsForSheet(_ bars: [BarVenue]) -> [BarVenue] {
        var seen = Set<UUID>()
        let unique = bars.filter { seen.insert($0.id).inserted }
        return unique.sorted { lhs, rhs in
            let lhsClass = venuePinDisplayClass(for: lhs)
            let rhsClass = venuePinDisplayClass(for: rhs)
            let lp = venuePinDisplayPriority(lhsClass)
            let rp = venuePinDisplayPriority(rhsClass)
            if lp != rp { return lp < rp }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func venueIsProForPinDisplay(_ bar: BarVenue) -> Bool {
        // Venue30 email/name hardcode removed. Organic energy never uses Pro.
        // Real Business Pro chrome requires a public entitlement signal on venue/business
        // inventory (not available on Discover map rows today without N RPCs / migration).
        // Do not treat all claimed/business venues as Pro.
        _ = bar
        return false
    }

    private func venuePinTint(for displayClass: VenuePinDisplayClass, hasLiveNow: Bool, energy: Int) -> Color {
        if displayClass == .proVenue {
            return proVenueGold
        }
        return hasLiveNow || energy >= livePulseThreshold ? FGColor.accentGreen : FGColor.accentBlue
    }

    private func venueClusterTint(for displayClass: VenuePinDisplayClass, energy: Int) -> Color {
        if displayClass == .proVenue {
            return proVenueGold
        }
        if displayClass == .businessVenue || displayClass == .claimedCommunity {
            return energy > 0 ? FGColor.accentGreen : FGColor.accentBlue
        }
        return energy > 0 ? FGColor.accentGreen : Color.gray
    }

    private var proVenueGold: Color {
        Color(red: 0.86, green: 0.63, blue: 0.22)
    }

    private var proVenueGoldDeep: Color {
        Color(red: 0.52, green: 0.35, blue: 0.11)
    }

    private var proVenueGlyphInk: Color {
        Color(red: 0.08, green: 0.06, blue: 0.025)
    }

    private func venuePinClaimStatusLabel(for displayClass: VenuePinDisplayClass) -> String {
        switch displayClass {
        case .unclaimedCommunity:
            return "unclaimed"
        case .claimedCommunity:
            return "approvedCommunityClaim"
        case .businessVenue:
            return "businessVenue"
        case .proVenue:
            return "proVenue"
        }
    }

    private func logVenuePinDisplayDebug(bar: BarVenue, displayClass: VenuePinDisplayClass) {
#if DEBUG
        guard isDiscoverTabSelected else { return }
        DebugLogGate.noisy("[VenuePinDisplayDebug] venueId=\(bar.id.uuidString.lowercased())")
        DebugLogGate.noisy("[VenuePinDisplayDebug] venueName=\(bar.name)")
        DebugLogGate.noisy("[VenuePinDisplayDebug] ownerEmail=\(bar.ownerEmail ?? bar.venueOwnerEmailRaw ?? bar.businessOwnerEmailRaw ?? "nil")")
        DebugLogGate.noisy("[VenuePinDisplayDebug] businessId=\(bar.businessId?.uuidString.lowercased() ?? "nil")")
        DebugLogGate.noisy("[VenuePinDisplayDebug] source=\(bar.originType ?? "nil")")
        DebugLogGate.noisy("[VenuePinDisplayDebug] claimStatus=\(venuePinClaimStatusLabel(for: displayClass))")
        DebugLogGate.noisy("[VenuePinDisplayDebug] displayClass=\(displayClass.rawValue)")
        DebugLogGate.noisy("[VenuePinDisplayDebug] isPro=\(displayClass == .proVenue)")
        DebugLogGate.noisy("[VenueProDebug] venue id=\(bar.id.uuidString.lowercased())")
        DebugLogGate.noisy("[VenueProDebug] venue name=\(bar.name)")
        DebugLogGate.noisy("[VenueProDebug] isPro=\(displayClass == .proVenue)")
        DebugLogGate.noisy("[VenueProDebug] clusterContainsPro=false")
#endif
    }

    private func logVenueClusterDisplayDebug(cluster: VenueCluster, displayClass: VenuePinDisplayClass) {
#if DEBUG
        guard isDiscoverTabSelected else { return }
        let containsPro = cluster.bars.contains { venuePinDisplayClass(for: $0) == .proVenue }
        let containsClaimed = cluster.bars.contains {
            let displayClass = venuePinDisplayClass(for: $0)
            return displayClass == .claimedCommunity || displayClass == .businessVenue || displayClass == .proVenue
        }
        DebugLogGate.noisy("[VenuePinDisplayDebug] clusterId=\(cluster.id)")
        DebugLogGate.noisy("[VenuePinDisplayDebug] clusterDisplayClass=\(displayClass.rawValue)")
        DebugLogGate.noisy("[VenuePinDisplayDebug] clusterContainsPro=\(containsPro)")
        DebugLogGate.noisy("[VenuePinDisplayDebug] clusterContainsClaimed=\(containsClaimed)")
        DebugLogGate.noisy("[VenueProDebug] clusterContainsPro=\(containsPro)")
        for venue in cluster.bars {
            DebugLogGate.noisy("[VenueProDebug] venue id=\(venue.id.uuidString.lowercased())")
            DebugLogGate.noisy("[VenueProDebug] venue name=\(venue.name)")
            DebugLogGate.noisy("[VenueProDebug] isPro=\(venuePinDisplayClass(for: venue) == .proVenue)")
        }
#endif
    }

    private func logVenueClusterSheetDebug(bar: BarVenue, displayClass: VenuePinDisplayClass) {
#if DEBUG
        DebugLogGate.noisy("[VenuePinDisplayDebug] sheetVenueName=\(bar.name)")
        DebugLogGate.noisy("[VenuePinDisplayDebug] sheetDisplayClass=\(displayClass.rawValue)")
#endif
    }

    private func venueClusterSheetStatusTitle(_ displayClass: VenuePinDisplayClass) -> String {
        switch displayClass {
        case .unclaimedCommunity:
            return L10n.t("venue_unclaimed", languageCode: appLanguageRaw)
        case .claimedCommunity, .businessVenue, .proVenue:
            // Presentation-only: claimed and Business Pro share identical badge text.
            // Pro differentiation remains gold styling via venueClusterSheetStatusTint / row chrome.
            return L10n.t("Business", languageCode: appLanguageRaw)
        }
    }

    private func venueClusterSheetStatusTint(_ displayClass: VenuePinDisplayClass) -> Color {
        switch displayClass {
        case .unclaimedCommunity:
            return Color.gray
        case .claimedCommunity, .businessVenue:
            return colorScheme == .dark ? Color.white.opacity(0.88) : Color.black.opacity(0.84)
        case .proVenue:
            return proVenueGold
        }
    }

    private func clusterSheetRowBackground(displayClass: VenuePinDisplayClass) -> Color {
        if displayClass == .proVenue {
            return Color(red: 1.0, green: 0.82, blue: 0.30).opacity(colorScheme == .dark ? 0.09 : 0.055)
        }
        return FGColor.cardBackground(colorScheme)
    }

    private func venueClusterSheetStatusPill(_ displayClass: VenuePinDisplayClass) -> some View {
        let title = venueClusterSheetStatusTitle(displayClass)
        let tint = venueClusterSheetStatusTint(displayClass)
        let isDarkClass = displayClass == .claimedCommunity || displayClass == .businessVenue
        return Text(title)
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .lineLimit(1)
            .foregroundStyle(isDarkClass ? Color.white.opacity(0.94) : tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background {
                Capsule(style: .continuous)
                    .fill(
                        isDarkClass
                            ? Color.black.opacity(colorScheme == .dark ? 0.62 : 0.78)
                            : tint.opacity(colorScheme == .dark ? 0.18 : 0.12)
                    )
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(displayClass == .proVenue ? 0.46 : 0.22), lineWidth: 0.8)
            }
    }

    private func venuePinChrome<Content: View>(
        displayClass: VenuePinDisplayClass,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isPro = displayClass == .proVenue
        return content()
            .overlay {
                if isPro {
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color(red: 1.0, green: 0.82, blue: 0.38).opacity(0.90),
                                    proVenueGoldDeep.opacity(0.72)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.7
                        )
                        .padding(-3)
                }
            }
            .shadow(
                color: isPro ? proVenueGold.opacity(colorScheme == .dark ? 0.34 : 0.24) : .clear,
                radius: isPro ? 11 : 0,
                y: isPro ? 3 : 0
            )
    }

    /// Chooses pin chrome from **venue + cached engagement** first; map zoom (`mapPinDisplayMode`) only caps density. Multi-game / trending venues never stay on the tiny sport-only pin at wide zoom.
    private func venueMarkerPinPresentation(
        bar: BarVenue,
        gamesToday: [SportsEvent],
        base: MapViewModel.MapPinDisplayMode,
        energyOverride: Int? = nil
    ) -> (mode: MapViewModel.MapPinDisplayMode, energy: Int, wantsEnriched: Bool) {
        let energy = energyOverride ?? viewModel.mapPinEnergyScore(bar: bar, gamesOnMapDay: gamesToday)
        let gamesOnSelectedDay = gamesToday.count
        let scheduledVenueGames = bar.games.count
        let wantsEnriched = gamesOnSelectedDay >= 2 || scheduledVenueGames >= 2 || energy > 0

        guard wantsEnriched else { return (base, energy, false) }

        let mode: MapViewModel.MapPinDisplayMode
        switch base {
        case .simple:
            mode = .compact
        case .compact:
            mode = .compact
        case .detailed:
            mode = gamesToday.isEmpty ? .compact : .detailed
        }
        return (mode, energy, true)
    }

    private func venueMapPinDisplayValues(for bar: BarVenue) -> VenueMapPinDisplayValues {
        let pinSnapshot = viewModel.discoverMapRenderSnapshot.venuePinsByID[bar.id]
        let gamesToday = pinSnapshot?.selectedDayGames ?? viewModel.selectedDayEventsForMap(bar)
        let goingTotal = pinSnapshot?.goingTotal ?? gamesToday.reduce(0) { total, game in
            if let id = viewModel.peekVenueEventIDForRender(for: bar, gameTitle: game.title) {
                return total + viewModel.interestCountForVenueEvent(id)
            }
            return total
        }
        let pin = venueMarkerPinPresentation(
            bar: bar,
            gamesToday: gamesToday,
            base: viewModel.mapPinDisplayMode,
            energyOverride: pinSnapshot?.pinEnergyScore
        )
        let hasLiveNow = pinSnapshot?.hasLiveNow ?? viewModel.hasLiveVenueEventNow(for: bar, events: gamesToday)
        let displayClass = venuePinDisplayClass(for: bar)
        return VenueMapPinDisplayValues(
            gamesToday: gamesToday,
            goingTotal: goingTotal,
            effectiveMode: pin.mode,
            isSelected: viewModel.selectedBar?.id == bar.id,
            hasLiveNow: hasLiveNow,
            energy: pin.energy,
            wantsEnriched: pin.wantsEnriched,
            tint: venuePinTint(
                for: displayClass,
                hasLiveNow: hasLiveNow,
                energy: pin.energy
            ),
            displayClass: displayClass
        )
    }

    private func venueClusterDisplayValues(for cluster: VenueCluster) -> VenueClusterDisplayValues {
        let clusterSnapshot = viewModel.discoverMapRenderSnapshot.venueClustersByID[cluster.id]
        let energy = clusterSnapshot.map {
            (maxScore: $0.maxEnergyScore, dominantSport: $0.dominantSport)
        } ?? viewModel.clusterVenueAnnotationEnergy(cluster: cluster)
        let displayClass = venueClusterDisplayClass(for: cluster)
        return VenueClusterDisplayValues(
            energy: energy,
            displayState: clusterDisplayState(cluster),
            tint: venueClusterTint(for: displayClass, energy: energy.maxScore),
            isActive: displayClass == .proVenue || energy.maxScore >= livePulseThreshold,
            displayClass: displayClass
        )
    }

    @ViewBuilder
    private func singleVenueMapPinButton(bar: BarVenue) -> some View {
        let pinSnapshot = viewModel.discoverMapRenderSnapshot.venuePinsByID[bar.id]
        let display = venueMapPinDisplayValues(for: bar)

#if DEBUG
        let _: Void = {
            guard pinSnapshot != nil else { return }
            DebugLogGate.noisy("[DiscoverMapSnapshotDebug] usingPinSnapshot=true")
        }()
#endif

#if DEBUG
        let _: Void = {
            guard display.wantsEnriched, isDiscoverTabSelected else { return }
            let style: String = {
                switch display.effectiveMode {
                case .simple: return "simple"
                case .compact: return "compact"
                case .detailed: return "detailed"
                }
            }()
            DebugLogGate.noisy("[MapMarker] venue=\(bar.name) games=\(display.gamesToday.count)/\(bar.games.count) score=\(display.energy) style=\(style)")
        }()
#endif

        Button {
            FGInteractionHaptics.selection()
#if DEBUG
            print("[VenuePreviewDebug] present source=single count=1")
            print("[VenuePreviewDebug] selected venueId=\(bar.id.uuidString.lowercased())")
#endif
            withAnimation(.spring()) {
                viewModel.clearPickupMapSelection()
                viewModel.centerMap(on: bar)
            }
        } label: {
            mapDepthStyledMarker(
                id: bar.id.uuidString.lowercased(),
                isSelected: display.isSelected,
                tint: display.tint
            ) {
                venuePinChrome(displayClass: display.displayClass) {
                    switch venuePinDisplayState(bar) {
                    case .gameScheduled:
                        switch display.effectiveMode {
                        case .simple:
                            simpleMapPin(
                                bar: bar,
                                gamesToday: display.gamesToday,
                                displayClass: display.displayClass
                            )

                        case .compact:
                            compactMapPin(
                                bar: bar,
                                gamesToday: display.gamesToday,
                                goingTotal: display.goingTotal,
                                liveScore: display.energy,
                                hasLiveNow: display.hasLiveNow,
                                displayClass: display.displayClass
                            )

                        case .detailed:
                            detailedMapPin(
                                bar: bar,
                                gamesToday: display.gamesToday,
                                goingTotal: display.goingTotal,
                                liveScore: display.energy,
                                hasLiveNow: display.hasLiveNow,
                                displayClass: display.displayClass
                            )
                        }
                    case .noGameScheduled:
                        noGameScheduledMapPin(displayClass: display.displayClass)
                    }
                }
            }
            .saturation(display.isSelected ? 0.82 : 0.66)
            .brightness(display.isSelected ? -0.01 : -0.035)
            .opacity(display.isSelected ? 0.96 : 0.82)
            .onAppear {
                logVenuePinDisplayDebug(bar: bar, displayClass: display.displayClass)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func multiVenueClusterAnnotation(cluster: VenueCluster) -> some View {
        let clusterSnapshot = viewModel.discoverMapRenderSnapshot.venueClustersByID[cluster.id]
        let display = venueClusterDisplayValues(for: cluster)
#if DEBUG
        let _: Void = {
            guard clusterSnapshot != nil, isDiscoverTabSelected else { return }
            DebugLogGate.noisy("[DiscoverMapSnapshotDebug] usingClusterSnapshot=true")
        }()
#endif
        Button {
            FGInteractionHaptics.selection()
            #if DEBUG
            if isDiscoverTabSelected {
                print(
                    "[DiscoverMap] cluster tap id=\(cluster.id) count=\(cluster.count) maxEnergy=\(display.energy.maxScore) center=(\(cluster.coordinate.latitude),\(cluster.coordinate.longitude))"
                )
            }
            #endif
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                viewModel.zoomTowardCluster(center: cluster.coordinate)
            }
            clusterForSheet = cluster
#if DEBUG
            print("[VenuePreviewDebug] present source=cluster count=\(cluster.count)")
#endif
        } label: {
            mapDepthStyledCluster(
                id: cluster.id,
                tint: display.tint,
                isActive: display.isActive
            ) {
                clusterMapPin(
                    cluster: cluster,
                    maxEnergy: display.energy.maxScore,
                    dominantSport: display.energy.dominantSport,
                    displayState: display.displayState,
                    displayClass: display.displayClass
                )
            }
            .saturation(0.68)
            .brightness(-0.03)
            .opacity(0.82)
            .onAppear {
                logVenueClusterDisplayDebug(cluster: cluster, displayClass: display.displayClass)
            }
        }
        .buttonStyle(.plain)
    }

    private func discoverLocationAuthStatusLabel(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "authorizedAlways"
        case .authorizedWhenInUse: return "authorizedWhenInUse"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    private var discoverPickupClustersForMap: [PickupGameCluster] {
        discoverAnnotationCache.pickupGameClusters
    }

    private var discoverPickupPlaceClustersForMap: [PickupPlaceCluster] {
        discoverAnnotationCache.pickupPlaceClusters
    }

    private var discoverVenueClustersForMap: [VenueCluster] {
        discoverAnnotationCache.venueClusters
    }

    private func buildDiscoverPickupClustersForMap() -> [PickupGameCluster] {
        guard viewModel.discoverPickupSubMode == .games else { return [] }
        // Same geographic meaning as calendar orange dots: only viewport-eligible pins.
        let rows = viewModel.pickupGamesVisibleAsMapPins(for: viewModel.currentMapRegionBounds())
            .filter { row in
                guard let lat = row.latitude, let lon = row.longitude else { return false }
                return CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
        return viewModel.clusteredPickupGamesForDiscoverMap(rows: rows)
    }

    private func buildDiscoverPickupPlaceClustersForMap() -> [PickupPlaceCluster] {
        guard isPickupPlacesMode else { return [] }
        return viewModel.clusteredPickupPlacesForDiscoverMap(
            rows: viewModel.pickupPlacesVisibleAsMapPins(for: viewModel.currentMapRegionBounds())
        )
    }

    private func buildDiscoverVenueClustersForMap() -> [VenueCluster] {
        let snapshotClusters = viewModel.discoverMapRenderSnapshotVenueClustersForMap()
        if !snapshotClusters.isEmpty {
#if DEBUG
            if isDiscoverTabSelected {
                DebugLogGate.noisy("[PerfPhase1B] mapUsingSnapshotClusters count=\(snapshotClusters.count)")
                DebugLogGate.noisy("[CommunityVenueDebug] clusteredVenueCount=\(snapshotClusters.count)")
                DebugLogGate.noisy("[CommunityVenueDebug] displayMode=\(viewModel.mapDisplayMode.rawValue) selectedSport=\(viewModel.selectedSport) loadedBars=\(viewModel.bars.count) visibleBars=\(viewModel.mapVisibleBars.count) source=snapshot")
            }
#endif
            return snapshotClusters
        }
        let fallback = viewModel.clusteredBars()
#if DEBUG
        if isDiscoverTabSelected {
            DebugLogGate.noisy("[PerfPhase1B] mapUsingFallbackClusters count=\(fallback.count)")
            DebugLogGate.noisy("[CommunityVenueDebug] clusteredVenueCount=\(fallback.count)")
            DebugLogGate.noisy("[CommunityVenueDebug] displayMode=\(viewModel.mapDisplayMode.rawValue) selectedSport=\(viewModel.selectedSport) loadedBars=\(viewModel.bars.count) visibleBars=\(viewModel.mapVisibleBars.count) source=fallback")
        }
#endif
        return fallback
    }

    private func rebuildDiscoverAnnotationCache(reason: String) {
        guard isDiscoverTabSelected else {
            DebugLogGate.discoverTabPerfVerbose(
                "[DiscoverPerf] inactive skipped heavy map work reason=rebuildDiscoverAnnotationCache trigger=\(reason)"
            )
            return
        }
        let key = discoverAnnotationCacheKey()
        if discoverAnnotationCache.key == key {
            Perf.cacheHit(name: "discoverAnnotationCache", detail: reason)
#if DEBUG
            if isDiscoverTabSelected {
                DebugLogGate.noisy("[MapPerf] cacheHit=true clusterRebuildReason=\(reason)")
                DebugLogGate.noisy("[MapPerf] cachedAnnotationCount=\(discoverAnnotationCache.counts.renderedCount(mode: viewModel.discoverMapContentMode))")
            }
#endif
            return
        }

        let venueClusters = buildDiscoverVenueClustersForMap()
        let pickupGameClusters = buildDiscoverPickupClustersForMap()
        let pickupPlaceClusters = buildDiscoverPickupPlaceClustersForMap()
        let counts = DiscoverAnnotationCounts(
            venue: venueClusters.count,
            pickupGames: pickupGameClusters.count,
            pickupPlaces: pickupPlaceClusters.count
        )

        discoverAnnotationCache = DiscoverAnnotationCache(
            key: key,
            venueClusters: venueClusters,
            pickupGameClusters: pickupGameClusters,
            pickupPlaceClusters: pickupPlaceClusters,
            counts: counts
        )

#if DEBUG
        if isDiscoverTabSelected {
            DebugLogGate.noisy("[MapPerf] cacheHit=false clusterRebuildReason=\(reason)")
            DebugLogGate.noisy("[MapPerf] cachedAnnotationCount=\(counts.renderedCount(mode: viewModel.discoverMapContentMode))")
            DebugLogGate.noisy("[MapPerf] animationsReduced=true")
        }
#endif
    }

    private func discoverAnnotationCacheKey() -> DiscoverAnnotationCacheKey {
        let selectedDay = Int(Calendar.current.startOfDay(for: viewModel.selectedDate).timeIntervalSince1970 / 86_400)
        let region = viewModel.cameraPosition.region
        let centerBucket = [
            String(format: "%.3f", region?.center.latitude ?? 0),
            String(format: "%.3f", region?.center.longitude ?? 0)
        ].joined(separator: ",")
        return DiscoverAnnotationCacheKey(
            mode: viewModel.discoverMapContentMode.rawValue,
            pickupSubMode: viewModel.discoverPickupSubMode.rawValue,
            selectedDay: selectedDay,
            selectedSport: viewModel.selectedSport,
            searchText: viewModel.debouncedDiscoverSearchText,
            mapDisplayMode: viewModel.mapDisplayMode.rawValue,
            visibleLatitudeBucket: String(format: "%.4f", viewModel.visibleLatitudeDelta),
            cameraCenterBucket: centerBucket,
            venueSnapshotKey: venueSnapshotAnnotationFingerprint(),
            barsCount: viewModel.bars.count,
            barsFingerprint: barsAnnotationFingerprint(),
            pickupGamesFingerprint: pickupGamesAnnotationFingerprint(),
            pickupPlacesFingerprint: pickupPlacesAnnotationFingerprint()
        )
    }

    private var discoverAnnotationInvalidationToken: String {
        discoverAnnotationCacheFingerprint(discoverAnnotationCacheKey())
    }

    private func discoverAnnotationCacheFingerprint(_ key: DiscoverAnnotationCacheKey) -> String {
        [
            key.mode,
            key.pickupSubMode,
            "\(key.selectedDay)",
            key.selectedSport,
            key.searchText,
            key.mapDisplayMode,
            key.visibleLatitudeBucket,
            key.cameraCenterBucket,
            key.venueSnapshotKey,
            "\(key.barsCount)",
            key.barsFingerprint,
            key.pickupGamesFingerprint,
            key.pickupPlacesFingerprint
        ].joined(separator: "|")
    }

    private func venueSnapshotAnnotationFingerprint() -> String {
        let snapshotKey = viewModel.discoverMapRenderSnapshot.key
        return [
            snapshotKey.mapDisplayMode.rawValue,
            snapshotKey.selectedSport,
            snapshotKey.selectedDay,
            snapshotKey.searchText,
            snapshotKey.venueIDFilterFingerprint,
            snapshotKey.visibleLatitudeDeltaBucket,
            "\(snapshotKey.venueCount)",
            "\(snapshotKey.eventRowCount)"
        ].joined(separator: ":")
    }

    private func barsAnnotationFingerprint() -> String {
        let rows = Array(viewModel.bars.prefix(96))
        return (["count:\(viewModel.bars.count)"] + rows.map { bar in
            [
                bar.id.uuidString.lowercased(),
                String(format: "%.4f", bar.coordinate.latitude),
                String(format: "%.4f", bar.coordinate.longitude),
                "\(bar.games.count)"
            ].joined(separator: ":")
        })
        .joined(separator: "|")
    }

    private func pickupGamesAnnotationFingerprint() -> String {
        let rows = Array(viewModel.pickupGamesForDiscoverMap.prefix(96))
        return (["count:\(viewModel.pickupGamesForDiscoverMap.count)"] + rows.map { row in
            [
                row.id.uuidString.lowercased(),
                String(format: "%.4f", row.latitude ?? 0),
                String(format: "%.4f", row.longitude ?? 0),
                row.status,
                "\(row.approved_join_count ?? -1)"
            ].joined(separator: ":")
        })
        .joined(separator: "|")
    }

    private func pickupPlacesAnnotationFingerprint() -> String {
        viewModel.pickupPlacesForDiscoverMap.prefix(96).map { place in
            [
                place.id.uuidString.lowercased(),
                String(format: "%.4f", place.latitude),
                String(format: "%.4f", place.longitude),
                place.sportTags.joined(separator: ",")
            ].joined(separator: ":")
        }
        .joined(separator: "|")
    }

    private func logPickupMapDebug(pickupGamesCount: Int, isPickupModeActive: Bool, annotationsRendered: Int) {
#if DEBUG
        DebugLogGate.noisy("[PickupMapDebug] pickupGames count=\(pickupGamesCount)")
        DebugLogGate.noisy("[PickupMapDebug] isPickupModeActive=\(isPickupModeActive)")
        DebugLogGate.noisy("[PickupMapDebug] annotationsRendered=\(annotationsRendered)")
#endif
    }

    private func pickupMarkerAllowsPulse(isSelected: Bool, activity: PickupGameMapMarkerActivity) -> Bool {
        isDiscoverTabSelected && (isSelected || activity == .high)
    }

    private func pickupMapMarkerDisplayValues(for row: PickupGameRow) -> PickupMapMarkerDisplayValues {
        let needed = pickupPlayersNeededDisplay(row)
        let isSelected = viewModel.selectedPickupGameForMap?.id == row.id
        let activity = pickupMarkerActivity(for: row)
        return PickupMapMarkerDisplayValues(
            needed: needed,
            isSelected: isSelected,
            badgeValue: pickupDemandBadgeText(for: needed),
            activity: activity,
            allowsPulse: pickupMarkerAllowsPulse(isSelected: isSelected, activity: activity),
            accentColor: viewModel.colorForSport(row.sport),
            reusedSportChipIcon: mapSportIconReusesSportChipIcon(row.sport)
        )
    }

    private func logDiscoverMapPerf(annotationCount: Int, source: String) {
#if DEBUG
        DebugLogGate.noisy("[MapPerf] annotationCount=\(annotationCount) diffApplied=true fullReload=false source=\(source)")
#endif
    }

    private func logMapEmptyStateDebug(
        mode: DiscoverMapContentMode,
        pickupAnnotationsCount: Int,
        venueAnnotationsCount: Int,
        renderedAnnotationsCount: Int
    ) {
#if DEBUG
        DebugLogGate.noisy("[MapEmptyStateDebug] mode=\(mode.rawValue)")
        DebugLogGate.noisy("[MapEmptyStateDebug] pickupAnnotationsCount=\(pickupAnnotationsCount)")
        DebugLogGate.noisy("[MapEmptyStateDebug] venueAnnotationsCount=\(venueAnnotationsCount)")
        DebugLogGate.noisy("[MapEmptyStateDebug] renderedAnnotationsCount=\(renderedAnnotationsCount)")
#endif
    }

    private func logDiscoverModeFilteringDebug() {
#if DEBUG
        let communityTypeFilter: String
        switch viewModel.discoverMapContentMode {
        case .venues:
            communityTypeFilter = "allow_null_and_non_play_exclude_play"
        case .pickupGames:
            communityTypeFilter = viewModel.discoverPickupSubMode == .places ? "pickup_places_bounds_only" : "none_pickup_games"
        }
        let visibleGameVenuesCount = viewModel.bars.filter { bar in
            !bar.isPickupPlayPlace && viewModel.venueHasVisibleGameToday(bar)
        }.count
        DebugLogGate.noisy("[DiscoverModeDebug] topLevelMode=\(viewModel.discoverMapContentMode.rawValue)")
        DebugLogGate.noisy("[DiscoverModeDebug] pickupSubMode=\(viewModel.discoverPickupSubMode.rawValue)")
        DebugLogGate.noisy("[DiscoverModeDebug] communityTypeFilter=\(communityTypeFilter)")
        DebugLogGate.noisy("[VenueEventsDebug] venueEventsCount=\(viewModel.venueEventRows.count)")
        DebugLogGate.noisy("[VenueEventsDebug] visibleGameVenuesCount=\(visibleGameVenuesCount)")
#endif
    }

    /// Shows the system user location dot only after access is granted, so the map does not imply tracking before the user allows it.
    private func discoverMapShowsUserAnnotation() -> Bool {
        _ = discoverMapLocationAuthVersion
        switch CLLocationManager().authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private var mapLayer: some View {
        if isDiscoverTabSelected {
            discoverActiveMapLayer
        } else {
            discoverInactiveMapPlaceholder
        }
    }

    private var discoverInactiveMapPlaceholder: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
    }

    private var discoverActiveMapLayer: some View {
        let pickupClusters = discoverPickupClustersForMap
        let pickupPlaceClusters = discoverPickupPlaceClustersForMap
        let venueClusters = discoverVenueClustersForMap
        let isPickupModeActive = viewModel.discoverMapContentMode == .pickupGames
        let _: Void = {
            guard isDiscoverTabSelected else { return }
            logDiscoverModeFilteringDebug()
            logDiscoverMapPerf(
                annotationCount: isPickupModeActive ? pickupClusters.count + pickupPlaceClusters.count : venueClusters.count,
                source: viewModel.discoverMapContentMode.rawValue
            )
            logPickupMapDebug(
                pickupGamesCount: viewModel.pickupGamesForDiscoverMap.count,
                isPickupModeActive: isPickupModeActive,
                annotationsRendered: isPickupModeActive ? pickupClusters.count + pickupPlaceClusters.count : 0
            )
        }()

        return Map(position: $viewModel.cameraPosition) {
            if discoverMapShowsUserAnnotation() {
                UserAnnotation()
            }

            if viewModel.discoverMapContentMode == .venues {
                ForEach(venueClusters) { cluster in
                    Annotation(
                        cluster.count == 1 ? cluster.bars.first?.name ?? "Venue" : "\(cluster.count) venues",
                        coordinate: cluster.coordinate
                    ) {
                        if cluster.count == 1, let bar = cluster.bars.first {
                            singleVenueMapPinButton(bar: bar)
                        } else {
                            multiVenueClusterAnnotation(cluster: cluster)
                        }
                    }
                }

            }

            if viewModel.discoverMapContentMode == .pickupGames, viewModel.discoverPickupSubMode == .games {
                ForEach(pickupClusters) { cluster in
                    Annotation(
                        cluster.count == 1 ? (cluster.rows.first?.title ?? "Pickup game") : "\(cluster.count) pickup games",
                        coordinate: cluster.coordinate
                    ) {
                        if cluster.count == 1, let row = cluster.rows.first {
                            pickupGameMapPinButton(row: row)
                        } else {
                            multiPickupGameClusterAnnotation(cluster: cluster)
                        }
                    }
                }
            }

            if isPickupPlacesMode {
                ForEach(pickupPlaceClusters) { cluster in
                    Annotation(
                        cluster.count == 1 ? cluster.rows.first?.name ?? "Pickup place" : "\(cluster.count) pickup places",
                        coordinate: cluster.coordinate
                    ) {
                        if cluster.count == 1, let place = cluster.rows.first {
                            pickupPlaceMapPinButton(place: place)
                        } else {
                            multiPickupPlaceClusterAnnotation(cluster: cluster)
                        }
                    }
                }
            }
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                dismissDiscoverSearchKeyboard()
            }
        )
        .onMapCameraChange(frequency: .continuous) { _ in
            if isSearchFocused {
                dismissDiscoverSearchKeyboard()
            }
        }
        .mapControls {
            MapCompass()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            dismissDiscoverSearchKeyboard()
            viewModel.noteDiscoverUserCameraInteractionIfStartupPending()
            viewModel.visibleLatitudeDelta = context.region.span.latitudeDelta
            let shouldWriteCameraPosition = viewModel.cameraPosition.region.map { currentRegion in
                !discoverCameraRegionIsEffectivelyIdentical(currentRegion, context.region)
            } ?? true
            if shouldWriteCameraPosition {
                viewModel.cameraPosition = .region(context.region)
            }
            rebuildDiscoverAnnotationCache(reason: "cameraEnd")

            let region = context.region
#if DEBUG
            print("[CommunityVenuePerf] cameraEnd=center=\(region.center.latitude),\(region.center.longitude) span=\(region.span.latitudeDelta),\(region.span.longitudeDelta)")
#endif
            mapVenueReloadTask?.cancel()
            let priorReloadRegion = lastMapVenueReloadRegion
            let precomputedDelta = priorReloadRegion.map { mapVenueReloadDelta(from: $0, to: region) }
            let isMajorRegionJump = precomputedDelta.map {
                mapVenueRegionJumpIsMajor(
                    distanceMovedMiles: $0.distanceMovedMiles,
                    boundsChangedSignificantly: $0.boundsChangedSignificantly
                )
            } ?? false
            logDiscoverRegionJump(
                oldRegion: priorReloadRegion,
                newRegion: region,
                distanceMovedMiles: precomputedDelta?.distanceMovedMiles,
                triggeredFastBoundsFetch: isMajorRegionJump
            )
            scheduleDiscoverActivityPanelMapSettled(
                region: region,
                isMajorRegionJump: isMajorRegionJump,
                movementIsMeaningful: precomputedDelta?.isMeaningful ?? true
            )
            if viewModel.discoverFocusedProGame != nil {
                viewModel.scheduleDiscoverTopVenuesForFocusedGameRefresh(reason: "mapCameraEnd")
            }
            mapVenueReloadTask = Task { @MainActor in
                if !isMajorRegionJump {
                    do {
                        try await Task.sleep(for: .milliseconds(250))
                    } catch {
                        return
                    }
                }
                guard !Task.isCancelled else { return }
                guard viewModel.pendingCitySearchVenueDebugContext == nil else {
#if DEBUG
                    print("[ManualMapReloadDebug] reloadScheduled=false")
                    print("[ManualMapReloadDebug] reloadSkippedReason=citySearchReloadInFlight")
#endif
                    return
                }
                if let delta = precomputedDelta {
#if DEBUG
                    print("[ManualMapReloadDebug] distanceMovedMiles=\(String(format: "%.2f", delta.distanceMovedMiles))")
#endif
                    guard delta.isMeaningful else {
#if DEBUG
                        print("[ManualMapReloadDebug] reloadScheduled=false")
                        print("[ManualMapReloadDebug] reloadSkippedReason=movementBelowThreshold")
#endif
                        return
                    }
                } else {
#if DEBUG
                    print("[ManualMapReloadDebug] distanceMovedMiles=initial")
#endif
                }
#if DEBUG
                print("[ManualMapReloadDebug] reloadScheduled=true")
#endif
                // Ordinary meaningful pans must not force-bypass pickup cache freshness.
                // Pickup/venues refresh for the new viewport with force=false so TTL / coalescing apply.
                await ensureDiscoverDatasetConsistency(
                    trigger: "mapRegionChanged",
                    forceCurrentModeReload: false,
                    fastRegionJump: isMajorRegionJump,
                    regionOverride: region
                )
            }
        }
        .ignoresSafeArea()
    }
    
    private var showDiscoverVisibleSearchEmptyHint: Bool {
        let counts = discoverAnnotationCache.counts
        let pickupAnnotationsCount = counts.pickupTotal
        let venueAnnotationsCount = counts.venue
        let renderedAnnotationsCount = viewModel.discoverMapContentMode == .pickupGames
            ? pickupAnnotationsCount
            : venueAnnotationsCount
        logMapEmptyStateDebug(
            mode: viewModel.discoverMapContentMode,
            pickupAnnotationsCount: pickupAnnotationsCount,
            venueAnnotationsCount: venueAnnotationsCount,
            renderedAnnotationsCount: renderedAnnotationsCount
        )
        let venueRegionMessageVisible = viewModel.discoverMapContentMode == .venues
            && viewModel.discoverRegionVenueLoadMessage != nil
        return renderedAnnotationsCount == 0 && !venueRegionMessageVisible
    }

    private var discoverVisibleSearchEmptyHintTitle: String {
        let languageCode = L10n.normalizedLanguageCode(appLanguageRaw)
        switch viewModel.discoverMapContentMode {
        case .venues:
            if viewModel.mapDisplayMode == .gamesOnly,
               let sport = discoverStatusSportDisplayName() {
                return String(
                    format: L10n.t("discover_empty_watch_hosting_sport_nearby_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    sport
                )
            }
            return viewModel.mapDisplayMode == .gamesOnly
                ? L10n.t("discover_empty_watch_hosting_nearby", languageCode: languageCode)
                : L10n.t("discover_empty_watch_spots_nearby", languageCode: languageCode)
        case .pickupGames:
            switch viewModel.discoverPickupSubMode {
            case .games:
                return L10n.t("discover_empty_pickup_games_nearby", languageCode: languageCode)
            case .places:
                return L10n.t("discover_empty_pickup_places_nearby", languageCode: languageCode)
            }
        }
    }

    private var discoverVisibleSearchEmptyHintSupporting: String {
        let languageCode = L10n.normalizedLanguageCode(appLanguageRaw)
        let hasSpecificSport = discoverStatusSportDisplayName() != nil
        switch viewModel.discoverMapContentMode {
        case .venues:
            // Date-dependent Watch → Hosting Games; location-only All Spots keeps zoom guidance.
            if viewModel.mapDisplayMode == .gamesOnly {
                return hasSpecificSport
                    ? L10n.t("discover_empty_recovery_hosting_date_sport", languageCode: languageCode)
                    : L10n.t("discover_empty_recovery_hosting_date", languageCode: languageCode)
            }
            return L10n.t("discover_empty_recovery_zoom", languageCode: languageCode)
        case .pickupGames:
            switch viewModel.discoverPickupSubMode {
            case .games:
                // Date-dependent Play → Games; Places stays location-only zoom guidance.
                return hasSpecificSport
                    ? L10n.t("discover_empty_recovery_pickup_games_date_sport", languageCode: languageCode)
                    : L10n.t("discover_empty_recovery_pickup_games_date", languageCode: languageCode)
            case .places:
                return L10n.t("discover_empty_recovery_zoom", languageCode: languageCode)
            }
        }
    }

    /// Play → Games only: encouragement shown with the create CTA (not while map games are loading).
    private var discoverVisibleSearchEmptyHintEncouragement: String? {
        guard showDiscoverPlayGamesEmptyCreateCTA else { return nil }
        return L10n.t(
            "discover_empty_pickup_encourage_organize",
            languageCode: L10n.normalizedLanguageCode(appLanguageRaw)
        )
    }

    /// Genuine Play → Games empty viewport with settled map data (no loading flicker).
    private var showDiscoverPlayGamesEmptyCreateCTA: Bool {
        guard showDiscoverVisibleSearchEmptyHint,
              viewModel.discoverMapContentMode == .pickupGames,
              viewModel.discoverPickupSubMode == .games,
              !viewModel.isLoadingPickupGamesForMap else {
            return false
        }
        return true
    }

    /// Empty-result map banner: compact adaptive card (+ optional Play → Games create CTA).
    @ViewBuilder
    private var discoverVisibleSearchEmptyHintBanner: some View {
        let tint = discoverDockAccentColor
        let title = discoverVisibleSearchEmptyHintTitle
        let supporting = discoverVisibleSearchEmptyHintSupporting
        let encouragement = discoverVisibleSearchEmptyHintEncouragement
        let showCreateCTA = showDiscoverPlayGamesEmptyCreateCTA
        let languageCode = L10n.normalizedLanguageCode(appLanguageRaw)
        let infoLabel: String = {
            if let encouragement, !encouragement.isEmpty {
                return "\(title). \(supporting). \(encouragement)"
            }
            return "\(title). \(supporting)"
        }()

        VStack(alignment: .leading, spacing: FGSpacing.sm) {
            discoverEmptyHintInformationalBody(
                title: title,
                supporting: supporting,
                encouragement: showCreateCTA ? encouragement : nil,
                tint: tint
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(infoLabel)
            .accessibilityHidden(!showCreateCTA)

            if showCreateCTA {
                discoverEmptyCreatePickupGameButton(languageCode: languageCode, tint: tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Padding must sit inside the glass clipShape so multiline copy is never corner-clipped.
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, FGSpacing.sm + 2)
        .discoverLightGlassCard(cornerRadius: 16, style: .overlay)
        .modifier(
            DiscoverEmptyHintAccessibilityModifier(
                combinesChildren: !showCreateCTA,
                combinedLabel: showCreateCTA ? nil : infoLabel
            )
        )
    }

    private struct DiscoverEmptyHintAccessibilityModifier: ViewModifier {
        let combinesChildren: Bool
        let combinedLabel: String?

        @ViewBuilder
        func body(content: Content) -> some View {
            if combinesChildren, let combinedLabel {
                content
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(combinedLabel)
            } else {
                content
                    .accessibilityElement(children: .contain)
            }
        }
    }

    private var discoverEmptyHintAccentIconName: String {
        viewModel.discoverMapContentMode == .venues ? "eye.fill" : "sportscourt.fill"
    }

    /// Single coherent empty-state body: compact accent + full wrapping copy (no competing side chip).
    @ViewBuilder
    private func discoverEmptyHintInformationalBody(
        title: String,
        supporting: String,
        encouragement: String?,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: FGSpacing.sm) {
            Image(systemName: discoverEmptyHintAccentIconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(tint.opacity(colorScheme == .dark ? 0.22 : 0.14))
                )
                .accessibilityHidden(true)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: FGSpacing.xs) {
                Text(title)
                    .font(FGTypography.cardTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.leading)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(supporting)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .multilineTextAlignment(.leading)
                    .lineSpacing(1)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let encouragement, !encouragement.isEmpty {
                    Text(encouragement)
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .multilineTextAlignment(.leading)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Compact leading-aligned Play CTA — intrinsic width, not a heavy full-bleed control.
    private func discoverEmptyCreatePickupGameButton(languageCode: String, tint: Color) -> some View {
        let label = L10n.t("discover_empty_create_pickup_game", languageCode: languageCode)
        return Button {
            openCreatePickupFromDiscoverEmptyState()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                Text(label)
                    .font(FGTypography.caption.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(colorScheme == .dark ? 0.18 : 0.12))
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(colorScheme == .dark ? 0.55 : 0.42), lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // Intrinsic capsule width; minHeight keeps a 44pt target without stretching full-bleed.
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }

    private func openCreatePickupFromDiscoverEmptyState() {
        guard viewModel.isAuthenticatedForSocialFeatures else {
            viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
            return
        }
        guard viewModel.canFanUsePickupGamesUI else {
            viewModel.logBusinessUserGateBlocked(action: "createPickupGameFromDiscoverEmpty")
            viewModel.showSocialActionToast(BusinessFanGateCopy.pickupFanOnly, isError: true)
            return
        }
        discoverEmptyCreatePickupFormMode = .add
    }

    private func discoverLogRedesignDebug() {
#if DEBUG
        print("[DiscoverRedesignDebug] layout=map_overlay_light")
        print("[DiscoverRedesignDebug] venuePickupToggle=floating")
        print("[DiscoverRedesignDebug] infoPill=compact")
        print("[DiscoverRedesignDebug] weatherPill=enabled")
        print("[DiscoverSportsFilterDebug] compactPills=true")
        print("[DiscoverSportsFilterDebug] chipHeight=36")
        print("[DiscoverSportsFilterDebug] iconSize=13")
#endif
    }

    private func discoverFixedTopOverlay(layoutWidth: CGFloat, layoutHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let discoverLocationHint {
                HStack(alignment: .top, spacing: FGSpacing.sm) {
                    Image(systemName: "location.slash.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(FGColor.accentYellow)
                    Text(discoverLocationHint)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .discoverLightGlassCard(style: .overlay)
            }

            discoverFloatingSearchBar
            discoverSearchAssistPanel(layoutHeight: layoutHeight)
            if !isSearchFocused {
                discoverSportsFilterGlassCard
            }

            if !viewModel.discoverBannerAnnouncements.isEmpty {
                DiscoverAnnouncementBannerCarouselView(
                    announcements: viewModel.discoverBannerAnnouncements,
                    isDiscoverTabVisible: isDiscoverTabSelected,
                    chipMetadata: { announcement in
                        viewModel.sponsoredAnnouncementChipMetadata(for: announcement)
                    },
                    onDismiss: { announcement in
                        viewModel.dismissDiscoverBannerAnnouncement(announcement)
                    },
                    onCTA: { announcement in
                        viewModel.handleDiscoverBannerAnnouncementCTA(announcement)
                    }
                )
            }

            HStack(spacing: 10) {
                discoverWeatherPill
                Spacer(minLength: 0)
            }

            if showDiscoverVisibleSearchEmptyHint {
                discoverVisibleSearchEmptyHintBanner
            }

            if let regionVenueLoadMessage = viewModel.discoverRegionVenueLoadMessage,
               viewModel.discoverMapContentMode == .venues,
               viewModel.mapVisibleBars.isEmpty {
                HStack(spacing: FGSpacing.sm) {
                    if viewModel.isLoadingMapVenues || viewModel.isRefreshingMapVenues {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(FGColor.accentBlue)
                    }
                    Text(regionVenueLoadMessage)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .discoverLightGlassCard(style: .overlay)
            }

            // Venue / place search hits render only inside `discoverSearchAssistPanel`.
            // Do not reintroduce per-row floating glass cards over the map.
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
        .padding(.horizontal, 18)
    }

    private func discoverFixedBottomOverlay(layoutWidth: CGFloat) -> some View {
        // Split into small type-check units: content + thin refresh-trigger layers.
        // Avoids reintroducing SwiftUI expression complexity in the bottom overlay.
        let content = discoverFixedBottomOverlayContent(layoutWidth: layoutWidth)
        let withCore = discoverActivityPanelCoreRefreshTriggers(content)
        let withPersonalization = discoverActivityPanelPersonalizationRefreshTriggers(withCore)
        let withGoing = discoverActivityPanelGoingRefreshTriggers(withPersonalization)
        return discoverActivityPanelSessionRefreshTriggers(withGoing)
    }

    @ViewBuilder
    private func discoverFixedBottomOverlayContent(layoutWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                if let mapHint = viewModel.followingMapNavigationMessage, !mapHint.isEmpty {
                    HStack(alignment: .top, spacing: FGSpacing.sm) {
                        FGStatusPill(title: "Going", kind: .custom(tint: FGColor.accentBlue))
                        Text(mapHint)
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .discoverLightGlassCard(style: .bottomControl)
                }

                if let socialToastText = viewModel.socialActionToastText,
                   !socialToastText.isEmpty {
                    discoverMapToastBanner(
                        text: socialToastText,
                        isError: viewModel.socialActionToastIsError
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if let mapStatusText = viewModel.mapStatusText,
                   !mapStatusText.isEmpty {
                    discoverMapStatusBanner(
                        text: mapStatusText,
                        isLoading: viewModel.isUpdatingMapGames,
                        isError: viewModel.mapStatusIsError
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(mapStatusText)
                    .onAppear {
                        AccessibilityNotification.Announcement(mapStatusText).post()
                    }
                    .onChange(of: mapStatusText) { previous, next in
                        let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty, trimmed != previous else { return }
                        AccessibilityNotification.Announcement(trimmed).post()
                    }
                }

                if viewModel.selectedBar != nil || viewModel.selectedPickupGameForMap != nil || viewModel.selectedPickupPlaceForMap != nil {
                    discoverBottomLeadingCard
                        .padding(.bottom, 2)
                }

                if viewModel.discoverFocusedProGame != nil {
                    DiscoverTopVenuesForGamePanel(viewModel: viewModel) { bar in
                        withAnimation(.spring()) {
                            viewModel.selectVenueFromDiscoverSearchResult(bar)
                        }
                    }
                    .padding(.bottom, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if !viewModel.isVenueOwnerLoggedIn,
                   viewModel.isLoggedIn || viewModel.isGuestDiscoverMode {
                    DiscoverActivityPanel(
                        presentation: discoverActivityPresentation,
                        isGuestMode: !viewModel.isLoggedIn,
                        onGuestCreateAccount: {
                            viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: true)
                        },
                        onMetricTap: { kind in
                            handleDiscoverTodayDashboardMetricTap(kind)
                        },
                        onNextEventTap: { insight in
                            handleDiscoverTodayDashboardNextEventTap(insight)
                        },
                        state: $discoverActivityPanelExpansion,
                        languageCode: L10n.normalizedLanguageCode(appLanguageRaw),
                        accountUserId: discoverActivityPanelPersistenceUserId,
                        onUserInteracted: {
                            discoverActivityPanelUserInteracted = true
                            cancelDiscoverActivityPanelAutoCollapse()
                            completeDiscoverActivityPanelIntroIfNeeded()
                        },
                        showsIntroInstruction: discoverActivityPanelShowIntroInstruction,
                        handleAttentionToken: discoverActivityPanelHandleAttentionToken
                    )
                    .padding(.bottom, discoverActivityPanelExpansion == .hidden ? 0 : 2)
                    .onAppear {
                        restoreDiscoverActivityPanelPreferenceIfNeeded()
                        refreshDiscoverActivityCounts(reason: "appear")
                        recordDiscoverActivityPanelShownIfNeeded()
                        presentDiscoverActivityPanelIntroIfNeeded()
                    }
                }

                discoverUnifiedInfoToggleControl(layoutWidth: layoutWidth)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)

            if isDiscoverTabSelected, FanGeoAdPolicy.shouldMountAdViews() {
                discoverBottomAdStrip(layoutWidth: layoutWidth)
                    .padding(.top, discoverBottomAdLoaded ? 6 : 0)
                    .padding(.bottom, discoverBottomAdLoaded ? 8 : 0)
            }

            Color.clear
                .frame(height: 78)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 0)
    }

    private func discoverActivityPanelCoreRefreshTriggers<Content: View>(_ content: Content) -> some View {
        content
            .onChange(of: viewModel.mapVisibleBars.count) { _, _ in
                refreshDiscoverActivityCounts(reason: "mapVisibleBars")
            }
            .onChange(of: viewModel.selectedDate) { _, _ in
                refreshDiscoverActivityCounts(reason: "selectedDate")
            }
            .onChange(of: viewModel.selectedSport) { _, _ in
                refreshDiscoverActivityCounts(reason: "selectedSport")
            }
            .onChange(of: viewModel.pickupGamesForDiscoverMap.count) { _, _ in
                refreshDiscoverActivityCounts(reason: "pickupGames")
            }
            .onChange(of: viewModel.discoverMapContentMode) { _, _ in
                refreshDiscoverActivityCounts(reason: "contentMode")
            }
            .onChange(of: viewModel.discoverPickupSubMode) { _, _ in
                refreshDiscoverActivityCounts(reason: "pickupSubMode")
            }
            .onChange(of: viewModel.mapDisplayMode) { _, _ in
                refreshDiscoverActivityCounts(reason: "mapDisplayMode")
            }
    }

    private func discoverActivityPanelPersonalizationRefreshTriggers<Content: View>(_ content: Content) -> some View {
        content
            .onChange(of: viewModel.discoverMapRenderSnapshotGeneration) { _, _ in
                refreshDiscoverActivityCounts(reason: "mapSnapshot")
            }
            .onChange(of: viewModel.discoverSettledViewedLocalityLabel) { _, _ in
                refreshDiscoverActivityCounts(reason: "viewedLocality")
            }
            .onChange(of: viewModel.venueEventRows.count) { _, _ in
                refreshDiscoverActivityCounts(reason: "venueEvents")
            }
            .onChange(of: viewModel.favoriteTeamsHydrationGeneration) { _, _ in
                refreshDiscoverActivityCounts(reason: "favoritesHydration")
            }
            .onChange(of: discoverFavoriteTeamIDsRaw) { _, _ in
                refreshDiscoverActivityCounts(reason: "favorites")
            }
            .onChange(of: viewModel.venueEventInterestIDs.count) { _, _ in
                refreshDiscoverActivityCounts(reason: "goingInterest")
            }
            .onChange(of: viewModel.followingTabUserVenueEventInterestIDs.count) { _, _ in
                refreshDiscoverActivityCounts(reason: "followingInterest")
            }
    }

    private func discoverActivityPanelGoingRefreshTriggers<Content: View>(_ content: Content) -> some View {
        content
            .onChange(of: viewModel.followingTabGoingItems.count) { _, _ in
                refreshDiscoverActivityCounts(reason: "goingItems")
            }
            .onChange(of: viewModel.myPickupGameJoinRequestCards.count) { _, _ in
                refreshDiscoverActivityCounts(reason: "pickupJoinCards")
            }
            .onChange(of: viewModel.myPickupGamesForSettings.count) { _, _ in
                refreshDiscoverActivityCounts(reason: "hostedPickup")
            }
    }

    private func discoverActivityPanelSessionRefreshTriggers<Content: View>(_ content: Content) -> some View {
        content
            .onChange(of: viewModel.isLoggedIn) { _, isLoggedIn in
                resetDiscoverActivityPanelSessionAttentionState()
                if isLoggedIn {
                    discoverActivityPanelDidRestorePreference = false
                    restoreDiscoverActivityPanelPreferenceIfNeeded()
                    refreshDiscoverActivityCounts(reason: "loggedIn")
                    presentDiscoverActivityPanelIntroIfNeeded()
                } else {
                    cancelDiscoverActivityPanelAutoCollapse()
                    discoverActivityPanelUserInteracted = false
                    discoverActivityPanelDidRestorePreference = false
                    clearDiscoverPersonalizedInsight()
                    restoreDiscoverActivityPanelPreferenceIfNeeded()
                    refreshDiscoverActivityCounts(reason: "loggedOut")
                    presentDiscoverActivityPanelIntroIfNeeded()
                }
            }
            .onChange(of: viewModel.currentUserAuthId) { _, _ in
                resetDiscoverActivityPanelSessionAttentionState()
                discoverActivityPanelDidRestorePreference = false
                clearDiscoverPersonalizedInsight()
                restoreDiscoverActivityPanelPreferenceIfNeeded()
                refreshDiscoverActivityCounts(reason: "authId")
                presentDiscoverActivityPanelIntroIfNeeded()
            }
            .onChange(of: isDiscoverTabSelected) { _, selected in
                if selected {
                    refreshDiscoverActivityCounts(reason: "tabSelected")
                    presentDiscoverActivityPanelIntroIfNeeded()
                } else {
                    cancelDiscoverActivityPanelAutoCollapse()
                }
            }
    }

    private var discoverActivityPanelPersistenceUserId: UUID? {
        viewModel.isLoggedIn ? viewModel.currentUserAuthId : nil
    }

    private func resetDiscoverActivityPanelSessionAttentionState() {
        cancelDiscoverActivityPanelAutoCollapse()
        discoverActivityPanelIntroActive = false
        discoverActivityPanelShowIntroInstruction = false
        discoverFansNearbyLastLoadedCount = nil
        // Do not reset handleAttentionToken — panel ignores 0; next pulse increments.
    }

    private func discoverLogLayoutDebug(layoutWidth: CGFloat) {
#if DEBUG
        print("[DiscoverLayoutDebug] overlayArchitecture=fixed")
        print("[DiscoverLayoutDebug] topOverlayIndependent=true")
        print("[DiscoverLayoutDebug] bottomOverlayIndependent=true")
        print("[DiscoverLayoutDebug] adaptiveLayoutDisabled=true")
        print("[DiscoverLayoutDebug] layersButtonMovedToWeatherRow=true")
        print("[DiscoverLayoutDebug] sportsChipsReduced=true")
        print("[DiscoverLayoutDebug] bottomBarLowered=true")
        print("[DiscoverLayoutDebug] unifiedInfoToggle=true")
        print("[DiscoverLayoutDebug] standaloneInfoPillRemoved=true")
        print("[DiscoverLayoutDebug] unifiedControlWidth=\(discoverUnifiedControlMaxWidth(for: layoutWidth))")
        print("[DiscoverLayoutDebug] weatherUsesUserLocationOnly=true")
        print("[DiscoverVisualPolishDebug] strongGlassPassApplied=true")
        print("[DiscoverVisualPolishDebug] overlayOpacityReduced=true")
        print("[DiscoverVisualPolishDebug] shadowReductionVisible=true")
        print("[DiscoverVisualPolishDebug] finalTopLighteningPass=true")
        print("[DiscoverBottomControlDebug] animatedToggle=true")
        print("[DiscoverBottomControlDebug] infoTextTransition=true")
        print("[DiscoverBottomControlDebug] hapticOnModeSwitch=true")
        print("[DiscoverAdPolishDebug] adSystemStrip=true")
        print("[DiscoverAdPolishDebug] adUsesOuterLayoutWidth=true")
        print("[DiscoverAdPolishDebug] adSlotPersistent=true")
#endif
    }

    private func discoverAdBannerAvailableWidth(for layoutWidth: CGFloat) -> CGFloat {
        max(1, floor(layoutWidth - 40))
    }

    private func discoverAdaptiveBannerSize(for layoutWidth: CGFloat) -> CGSize {
        AdaptiveBannerLayout.adaptiveBannerSize(
            forAvailableWidth: discoverAdBannerAvailableWidth(for: layoutWidth)
        )
    }

    private var discoverBottomControlModeSpring: Animation {
        .spring(response: 0.28, dampingFraction: 0.82)
    }

    private var discoverBottomControlStatusTextAnimation: Animation {
        .easeInOut(duration: 0.2)
    }

    private func discoverUnifiedControlMaxWidth(for layoutWidth: CGFloat) -> CGFloat {
        max(300, layoutWidth - 20)
    }

    private func discoverWatchPlayTileSide(for layoutWidth: CGFloat) -> CGFloat {
        if layoutWidth < 360 { return 46 }
        if layoutWidth < 430 { return 48 }
        return 50
    }

    /// Compact contextual width — Hosting Games wraps to two lines; both segments stay visible.
    private func discoverDockContextualFilterWidth(for layoutWidth: CGFloat) -> CGFloat {
        if viewModel.discoverMapContentMode == .venues {
            // Slightly wider than Play so All Spots (~44%) and Hosting Games (~56%) both fit.
            if layoutWidth < 360 { return 118 }
            if layoutWidth < 400 { return 126 }
            return 134
        }
        if layoutWidth < 360 { return 96 }
        if layoutWidth < 400 { return 104 }
        return 112
    }

    private func discoverDockStatusMinWidth(for layoutWidth: CGFloat) -> CGFloat {
        if layoutWidth < 360 { return 108 }
        if layoutWidth < 400 { return 120 }
        return 132
    }

    private var discoverDockAccentColor: Color {
        viewModel.discoverMapContentMode == .venues ? FGColor.intentWatch : FGColor.intentPlay
    }

    @ViewBuilder
    private func discoverDockContextualFilterControl(layoutWidth: CGFloat) -> some View {
        let languageCode = L10n.normalizedLanguageCode(appLanguageRaw)
        let filterWidth = discoverDockContextualFilterWidth(for: layoutWidth)
        let isWatch = viewModel.discoverMapContentMode == .venues

        ZStack {
            Capsule(style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))

            if isWatch {
                discoverDockTwoSegmentFilter(
                    width: filterWidth,
                    leftShare: 0.44,
                    leftTitle: L10n.t("discover_filter_all_spots", languageCode: languageCode),
                    rightTitle: L10n.t("discover_filter_hosting_games", languageCode: languageCode),
                    leftSelected: viewModel.mapDisplayMode == .allSpots,
                    tint: FGColor.intentWatch,
                    leftAllowsMultiline: false,
                    rightAllowsMultiline: true,
                    matchedGeometryID: "discoverVenueDisplaySelection",
                    onSelectLeft: {
                        guard viewModel.mapDisplayMode != .allSpots else { return }
                        dismissDiscoverSearchKeyboard()
                        FGInteractionHaptics.softImpact()
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            viewModel.mapDisplayMode = .allSpots
                        }
                        showMapDisplayModeHint(L10n.t("discover_filter_all_spots", languageCode: languageCode))
                    },
                    onSelectRight: {
                        guard viewModel.mapDisplayMode != .gamesOnly else { return }
                        dismissDiscoverSearchKeyboard()
                        FGInteractionHaptics.softImpact()
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            viewModel.mapDisplayMode = .gamesOnly
                        }
                        showMapDisplayModeHint(L10n.t("discover_filter_hosting_games", languageCode: languageCode))
                    }
                )
            } else {
                discoverDockTwoSegmentFilter(
                    width: filterWidth,
                    leftShare: 0.50,
                    leftTitle: L10n.t("discover_filter_places", languageCode: languageCode),
                    rightTitle: L10n.t("discover_filter_games", languageCode: languageCode),
                    leftSelected: viewModel.discoverPickupSubMode == .places,
                    tint: FGColor.intentPlay,
                    leftAllowsMultiline: false,
                    rightAllowsMultiline: false,
                    matchedGeometryID: "discoverPickupSubModeSelection",
                    onSelectLeft: {
                        guard viewModel.discoverPickupSubMode != .places else { return }
                        dismissDiscoverSearchKeyboard()
                        FGInteractionHaptics.selection()
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            viewModel.discoverPickupSubMode = .places
                        }
                    },
                    onSelectRight: {
                        guard viewModel.discoverPickupSubMode != .games else { return }
                        dismissDiscoverSearchKeyboard()
                        FGInteractionHaptics.selection()
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            viewModel.discoverPickupSubMode = .games
                        }
                    }
                )
            }
        }
        .frame(width: filterWidth, height: 44)
        .frame(minHeight: 48)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("discover_dock_contextual_a11y_group", languageCode: languageCode))
        .animation(discoverBottomControlModeSpring, value: viewModel.discoverMapContentMode)
        .animation(discoverBottomControlModeSpring, value: viewModel.mapDisplayMode)
        .animation(discoverBottomControlModeSpring, value: viewModel.discoverPickupSubMode)
    }

    /// Shared Watch/Play contextual two-segment control. Fixed proportional widths prevent one
    /// segment from crushing the other (Watch previously used layoutPriority on Hosting Games).
    private func discoverDockTwoSegmentFilter(
        width: CGFloat,
        leftShare: CGFloat,
        leftTitle: String,
        rightTitle: String,
        leftSelected: Bool,
        tint: Color,
        leftAllowsMultiline: Bool,
        rightAllowsMultiline: Bool,
        matchedGeometryID: String,
        onSelectLeft: @escaping () -> Void,
        onSelectRight: @escaping () -> Void
    ) -> some View {
        let clampedShare = min(0.58, max(0.42, leftShare))
        let leftWidth = floor(width * clampedShare)
        let rightWidth = width - leftWidth

        return HStack(spacing: 0) {
            discoverDockContextualSegment(
                title: leftTitle,
                selected: leftSelected,
                tint: tint,
                allowsMultiline: leftAllowsMultiline,
                matchedGeometryID: matchedGeometryID,
                action: onSelectLeft
            )
            .frame(width: leftWidth, height: 44)

            discoverDockContextualSegment(
                title: rightTitle,
                selected: !leftSelected,
                tint: tint,
                allowsMultiline: rightAllowsMultiline,
                matchedGeometryID: matchedGeometryID,
                action: onSelectRight
            )
            .frame(width: rightWidth, height: 44)
        }
        .frame(width: width, height: 44)
    }

    private func discoverDockContextualSegment(
        title: String,
        selected: Bool,
        tint: Color,
        allowsMultiline: Bool,
        matchedGeometryID: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                if selected {
                    discoverBottomModeSelectionCapsule(tint: tint)
                        .padding(2)
                        .matchedGeometryEffect(id: matchedGeometryID, in: discoverModeToggleNamespace)
                }
                discoverBottomModeSegmentText(title, selected: selected, allowsMultiline: allowsMultiline)
            }
        }
        .buttonStyle(DiscoverModeSegmentButtonStyle())
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func discoverUnifiedInfoToggleControl(layoutWidth: CGFloat) -> some View {
        let languageCode = L10n.normalizedLanguageCode(appLanguageRaw)
        let dividerPad: CGFloat = layoutWidth < 360 ? 3 : 5
        return HStack(spacing: 0) {
            discoverUnifiedStatusLeading
                .frame(minWidth: discoverDockStatusMinWidth(for: layoutWidth), maxWidth: .infinity, alignment: .leading)
                .layoutPriority(3)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    String(
                        format: L10n.t("discover_dock_status_a11y_format", languageCode: languageCode),
                        locale: Locale(identifier: languageCode),
                        discoverInfoMessage
                    )
                )

            discoverDockVerticalDivider
                .padding(.horizontal, dividerPad)

            discoverWatchPlayIntentToggle(layoutWidth: layoutWidth)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)

            discoverDockVerticalDivider
                .padding(.horizontal, dividerPad)

            discoverDockContextualFilterControl(layoutWidth: layoutWidth)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(0)
        }
        .padding(.leading, layoutWidth < 360 ? 8 : 10)
        .padding(.trailing, layoutWidth < 360 ? 6 : 8)
        .frame(width: discoverUnifiedControlMaxWidth(for: layoutWidth), height: 66)
        .discoverLightGlassCard(cornerRadius: 24, style: .bottomControl)
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.10 : 0.04), radius: 6, y: 2)
        .frame(maxWidth: .infinity)
    }

    private var discoverDockVerticalDivider: some View {
        Rectangle()
            .fill(FGColor.divider(colorScheme))
            .frame(width: 1, height: 36)
            .accessibilityHidden(true)
    }

    private var discoverUnifiedStatusLeading: some View {
        let accent = discoverDockAccentColor
        return HStack(alignment: .center, spacing: 5) {
            if discoverSummaryLoadingFeedbackVisible {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: discoverDockStatusSystemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(accent.opacity(colorScheme == .dark ? 0.24 : 0.16))
                    )
                    .animation(discoverBottomControlModeSpring, value: viewModel.discoverMapContentMode)
                    .animation(discoverBottomControlModeSpring, value: viewModel.discoverPickupSubMode)
                    .animation(discoverBottomControlModeSpring, value: viewModel.mapDisplayMode)
            }

            Text(discoverInfoMessage)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(accent)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(discoverInfoMessage)
                .accessibilityHidden(true)
                .transition(.opacity)
                .onAppear { discoverLogEmptyStateDebug() }
                .onChange(of: discoverInfoMessage) { _, _ in
                    discoverLogEmptyStateDebug()
                }
        }
        .animation(discoverBottomControlStatusTextAnimation, value: discoverInfoMessage)
    }

    private var discoverDockStatusSystemImage: String {
        switch viewModel.discoverMapContentMode {
        case .venues:
            return viewModel.mapDisplayMode == .gamesOnly ? "tv.fill" : "sportscourt.fill"
        case .pickupGames:
            return isPickupPlacesMode ? "mappin.and.ellipse" : "figure.run"
        }
    }

    private var discoverInfoMessage: String {
        discoverUnifiedStatusText
    }

    private func discoverLogBottomControlModeSwitch(to mode: DiscoverMapContentMode) {
#if DEBUG
        print("[DiscoverBottomControlDebug] animatedToggle=true mode=\(mode.rawValue)")
        print("[DiscoverBottomControlDebug] hapticOnModeSwitch=true")
        print("[DiscoverBottomControlDebug] matchedGeometrySelection=true")
        print("[DiscoverBottomControlDebug] infoTextTransition=true")
#endif
    }

    private func discoverLogEmptyStateDebug() {
#if DEBUG
        print("[DiscoverEmptyStateDebug] message=\(discoverUnifiedStatusText)")
#endif
    }

    private var discoverFloatingSearchBar: some View {
        GeometryReader { geo in
            let languageCode = L10n.normalizedLanguageCode(appLanguageRaw)
            HStack(spacing: 0) {
                discoverHelpButton
                    .padding(.leading, 10)

                DiscoverFloatingSearchBarRotatingPlaceholder(
                    viewModel: viewModel,
                    isFocused: $isSearchFocused,
                    isDiscoverTabSelected: isDiscoverTabSelected,
                    languageCode: languageCode,
                    compactWidth: geo.size.width < 340,
                    cornerRadius: discoverLightGlassCornerRadius,
                    onClear: {
                        discoverFanSearchController.clear()
                        discoverProGameSearchController.clear()
                        dismissDiscoverSearchKeyboard()
                    },
                    onSubmit: {
                        submitDiscoverSearchFromReturn()
                    }
                ) {
                    HStack(spacing: 6) {
                        if viewModel.isDiscoverVenueSearchLoading
                            || discoverFanSearchController.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        }
                        discoverIntegratedLocationButton
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .discoverLightGlassCard(cornerRadius: discoverLightGlassCornerRadius, style: .searchBar)
        }
        .frame(height: 52)
        .onChange(of: viewModel.searchText) { _, _ in
            refreshDiscoverSearchSuggestions()
        }
        .onChange(of: isSearchFocused) { _, focused in
            if focused {
                // Every new Discover search session starts on All.
                discoverSearchResultFilter = .all
            } else {
                // Session ended (dismiss / leave search mode).
                discoverSearchResultFilter = .all
            }
            refreshDiscoverSearchSuggestions()
        }
        .onChange(of: viewModel.isAuthenticatedForSocialFeatures) { _, _ in
            refreshDiscoverSearchSuggestions()
        }
        .onChange(of: viewModel.liveMatches.count) { _, _ in
            refreshDiscoverSearchSuggestions()
        }
    }

    private var discoverHelpButton: some View {
        Button {
            dismissDiscoverSearchKeyboard()
            guard !showFirstLaunchLanguageSelector else { return }
            showDiscoverHelpSheet = true
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(showFirstLaunchLanguageSelector)
        .accessibilityLabel("Discover help")
    }

    private func presentStartupGuideIfNeeded() {
        guard isDiscoverTabSelected else { return }
        if presentFirstLaunchLanguageSelectorIfNeeded() { return }
        if presentPostSignupWelcomeGuideIfNeeded() { return }
        guard !didPresentStartupGuideThisSession else { return }
        guard !showFirstLaunchLanguageSelector else { return }
        guard !FanGeoStartupGuidePreferences.shouldHideAtStartup(for: viewModel.currentUserAuthId) else { return }
        didPresentStartupGuideThisSession = true
        showDiscoverHelpSheet = true
    }

    /// Installation-level and/or post-account-creation language selector; always precedes Welcome Guide when required.
    @discardableResult
    private func presentFirstLaunchLanguageSelectorIfNeeded() -> Bool {
        guard isDiscoverTabSelected else { return false }
        if showFirstLaunchLanguageSelector { return true }
        guard !showDiscoverHelpSheet else { return false }

        let currentUserId = viewModel.currentUserAuthId
        let needsInstall = !FanGeoFirstLaunchLanguagePreferences.hasCompleted
        let needsPostAccount = FanGeoFirstLaunchLanguagePreferences.shouldPresentPostAccountCreation(
            currentUserId: currentUserId
        )
        guard needsInstall || needsPostAccount else { return false }

        // Installation prompt is once per session; post-account may follow later in the same session.
        if needsInstall && !needsPostAccount {
            guard !didPresentFirstLaunchLanguageThisSession else { return false }
        }

        if needsInstall {
            FanGeoFirstLaunchLanguagePreferences.applyDetectedLanguageForFirstLaunchIfNeeded()
            let detected = FanGeoFirstLaunchLanguagePreferences.resolvePreferredSupportedLanguageCode()
            firstLaunchDetectedLanguageCode = detected
            appLanguageRaw = detected
        } else {
            let seed = FanGeoFirstLaunchLanguagePreferences.resolveLanguageForPostAccountCreation(
                currentAppLanguage: appLanguageRaw
            )
            firstLaunchDetectedLanguageCode = seed
            appLanguageRaw = seed
        }

        languageSelectorPostAccountCompletionUserId = needsPostAccount ? currentUserId : nil
        didPresentFirstLaunchLanguageThisSession = true
        showFirstLaunchLanguageSelector = true
#if DEBUG
        print(
            "[FirstLaunchLanguage] presented install=\(needsInstall) postAccount=\(needsPostAccount) detected=\(firstLaunchDetectedLanguageCode)"
        )
#endif
        return true
    }

    /// Forces the existing Welcome guide once after a newly completed fan signup (may bypass startup suppression once).
    @discardableResult
    private func presentPostSignupWelcomeGuideIfNeeded() -> Bool {
        guard isDiscoverTabSelected else { return false }
        guard !showFirstLaunchLanguageSelector else { return false }
        guard viewModel.hasPostSignupDiscoverWelcomeGuide else { return false }
        guard viewModel.consumePostSignupDiscoverWelcomeGuide(currentUserId: viewModel.currentUserAuthId) else {
            return false
        }
        didPresentStartupGuideThisSession = true
        pendingDiscoverActivityPanelIntro = true
        showDiscoverHelpSheet = true
        FanGeoAnalyticsService.record(
            eventName: "onboarding_guide_presented_after_signup",
            sport: nil,
            metadata: [:],
            updateLastActive: false
        )
#if DEBUG
        print("[PostSignupRoute] presented existing DiscoverHelpSheet")
#endif
        return true
    }

    private func handleDiscoverTodayDashboardMetricTap(_ kind: DiscoverActivityPanelItem.Kind) {
        switch kind {
        case .fansNearby:
            // Presentation marks tappable only for a valid loaded count > 0.
            viewModel.enqueueDiscoverTodayDashboardNav(.chatFansLiveNow)
        case .venuePlansToday:
            viewModel.enqueueDiscoverTodayDashboardNav(.goingVenueGamesToday)
        case .pickupPlansToday:
            viewModel.enqueueDiscoverTodayDashboardNav(.goingPickupGamesToday)
        case .suggestedFans:
            viewModel.enqueueDiscoverTodayDashboardNav(.accountSuggestedFans)
        case .pickupSoon, .favoriteTeam:
            break
        }
    }

    private func handleDiscoverTodayDashboardNextEventTap(_ insight: DiscoverPersonalizedInsight) {
        switch insight.kind {
        case .pickup:
            if let pickupId = insight.destinationPickupGameId {
                pickupGameDetailNav = PickupDetailNavigationToken(id: pickupId)
                return
            }
            viewModel.enqueueDiscoverTodayDashboardNav(.goingPickupGamesUpcoming)
        case .going:
            if let venueId = insight.destinationVenueId,
               let bar = viewModel.bars.first(where: { $0.id == venueId })
                ?? viewModel.mapVisibleBars.first(where: { $0.id == venueId })
                ?? viewModel.followingTabGoingItems.first(where: { $0.bar.id == venueId })?.bar {
                viewModel.selectVenueForPreview(bar, source: "discoverActivityNextEvent")
                return
            }
            viewModel.enqueueDiscoverTodayDashboardNav(.goingVenueGamesUpcoming)
        case .favoriteTeamVenue, .empty:
            break
        }
    }

    private func refreshDiscoverActivityCounts(reason: String) {
        let started = Date()
        let isGuest = !viewModel.isLoggedIn
        let fansCenter = viewModel.cameraPosition.region?.center ?? viewModel.currentUserLocation

        if let coordinate = viewModel.currentUserLocation {
            PresenceService.shared.updateHeartbeatLocation(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
            if reason == "appear" || reason == "loggedIn" || reason == "tabSelected" {
                PresenceService.shared.sendHeartbeat(reason: "discoverFansNearby:\(reason)", force: true)
            }
        }

        if !isGuest, !viewModel.isVenueOwnerLoggedIn {
            Task { @MainActor in
                // Let the heartbeat write land before the first nearby count when opening Discover.
                if reason == "appear" || reason == "loggedIn" || reason == "tabSelected" {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                }
                await FansNearbyService.shared.refreshIfNeeded(
                    authId: viewModel.currentUserAuthId,
                    isBusinessAccount: viewModel.currentUserIsBusinessAccount,
                    center: fansCenter,
                    force: reason == "loggedIn" || reason == "authId" || reason == "appear" || reason == "tabSelected",
                    reason: reason
                )
                applyDiscoverActivityPresentation(reason: "fansNearby:\(reason)")
            }
        }

        applyDiscoverActivityPresentation(reason: reason)
#if DEBUG
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        print("[DiscoverActivityPanelPerf] presentationUpdated durationMs=\(ms) reason=\(reason)")
#endif
    }

    /// After camera settle: clear stale city names, resolve viewport locality, refresh map-centered fans.
    private func scheduleDiscoverActivityPanelMapSettled(
        region: MKCoordinateRegion,
        isMajorRegionJump: Bool,
        movementIsMeaningful: Bool
    ) {
        let center = region.center
        guard CLLocationCoordinate2DIsValid(center) else { return }
        let bucket = MapViewModel.discoverActivityLocalityBucket(for: center)
        let bucketChanged = discoverActivityLocalityLastBucket.map {
            $0.lat != bucket.lat || $0.lng != bucket.lng
        } ?? true

        if bucketChanged {
            discoverActivityLocalityLastBucket = bucket
            viewModel.invalidateDiscoverSettledViewedLocality(reason: "mapSettleBucketChange")
            applyDiscoverActivityPresentation(reason: "mapSettleInvalidate")
        }

        guard movementIsMeaningful || bucketChanged || isMajorRegionJump else { return }

        discoverActivityLocalitySettleTask?.cancel()
        discoverActivityLocalitySettleTask = Task { @MainActor in
            if !isMajorRegionJump {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }

            let pinLocality = DiscoverActivityPanelPresentationBuilder.pinDerivedLocality(viewModel: viewModel)
            viewModel.scheduleDiscoverSettledViewedLocalityResolve(
                center: center,
                pinDerivedLocality: pinLocality
            )

            if viewModel.isLoggedIn, !viewModel.isVenueOwnerLoggedIn {
                await FansNearbyService.shared.refreshIfNeeded(
                    authId: viewModel.currentUserAuthId,
                    isBusinessAccount: viewModel.currentUserIsBusinessAccount,
                    center: center,
                    force: false,
                    reason: "mapSettle"
                )
            }
            applyDiscoverActivityPresentation(reason: "mapSettle")
        }
    }

    private func applyDiscoverActivityPresentation(reason: String) {
        let languageCode = L10n.normalizedLanguageCode(appLanguageRaw)
        let isGuest = !viewModel.isLoggedIn
        let cacheKey = DiscoverActivityPanelPresentationBuilder.cacheKey(
            viewModel: viewModel,
            favoritesRaw: discoverFavoriteTeamIDsRaw,
            languageCode: languageCode,
            isGuest: isGuest
        )
        if cacheKey == discoverActivityPresentationCacheKey {
            return
        }

        let next = DiscoverActivityPanelPresentationBuilder.build(
            viewModel: viewModel,
            favoritesRaw: discoverFavoriteTeamIDsRaw,
            languageCode: languageCode,
            isGuest: isGuest
        )
        discoverActivityPresentationCacheKey = cacheKey
        discoverActivityPresentation = next
        recordDiscoverPersonalizedInsightsShownIfNeeded(next)
        evaluateDiscoverActivityHandleAttentionPulse(reason: reason)
#if DEBUG
        print("[DiscoverActivityPanelPerf] presentationApplied reason=\(reason) metrics=\(next.metricItems.count)")
#endif
    }

    private func clearDiscoverPersonalizedInsight() {
        discoverActivityPresentation = .empty
        discoverActivityPresentationCacheKey = nil
        discoverPersonalizedInsightAnalyticsToken = nil
        discoverFansNearbyLastLoadedCount = nil
        FansNearbyService.shared.clear(reason: "signedOut")
    }

    /// Pulse once on valid loaded Fans Nearby 0 → positive while Discover is visible.
    private func evaluateDiscoverActivityHandleAttentionPulse(reason: String) {
        guard isDiscoverTabSelected else { return }
        guard viewModel.isLoggedIn, !viewModel.isVenueOwnerLoggedIn else { return }
        guard case .loaded(let count) = FansNearbyService.shared.cachedCount(
            for: viewModel.currentUserAuthId,
            center: viewModel.cameraPosition.region?.center
        ) else {
            return
        }
        let previous = discoverFansNearbyLastLoadedCount
        discoverFansNearbyLastLoadedCount = count
        guard let previous, previous == 0, count > 0 else { return }
        fireDiscoverActivityHandleAttentionPulse()
#if DEBUG
        print("[DiscoverActivityPanel] handlePulse reason=fansNearbyZeroToPositive source=\(reason)")
#endif
    }

    private func fireDiscoverActivityHandleAttentionPulse() {
        discoverActivityPanelHandleAttentionToken &+= 1
    }

    private func recordDiscoverPersonalizedInsightsShownIfNeeded(
        _ presentation: DiscoverActivityPanelPresentation
    ) {
        let insights = [presentation.favoriteTeamInsight, presentation.timelyInsight].compactMap { $0 }
        guard !insights.isEmpty else { return }
        let token = insights
            .map { "\(DiscoverPersonalizedInsightBuilder.analyticsTypeToken(for: $0.kind))|\($0.countBucket)" }
            .joined(separator: ";")
        guard discoverPersonalizedInsightAnalyticsToken != token else { return }
        discoverPersonalizedInsightAnalyticsToken = token
        for insight in insights {
            FanGeoAnalyticsService.record(
                eventName: "discover_personalized_insight_shown",
                sport: nil,
                metadata: [
                    "type": DiscoverPersonalizedInsightBuilder.analyticsTypeToken(for: insight.kind),
                    "count_bucket": insight.countBucket
                ],
                updateLastActive: false
            )
        }
    }

    private func restoreDiscoverActivityPanelPreferenceIfNeeded() {
        guard !viewModel.isVenueOwnerLoggedIn else { return }
        guard viewModel.isLoggedIn || viewModel.isGuestDiscoverMode else { return }
        guard !discoverActivityPanelDidRestorePreference else { return }
        discoverActivityPanelDidRestorePreference = true
        // Expanded never restores across launches — only hidden or compact.
        // Guests use `discoverActivityPanelState.guest` via nil account id.
        // Skip overwrite while first-Discover intro is actively expanded.
        guard !discoverActivityPanelIntroActive else { return }
        discoverActivityPanelExpansion = FanGeoDiscoverActivityPanelPreferences.restoredState(
            for: discoverActivityPanelPersistenceUserId
        )
    }

    private func recordDiscoverActivityPanelShownIfNeeded() {
        guard !discoverActivityPanelShownAnalytics else { return }
        guard discoverActivityPanelExpansion != .hidden else { return }
        discoverActivityPanelShownAnalytics = true
        FanGeoAnalyticsService.record(
            eventName: "discover_activity_panel_shown",
            sport: nil,
            metadata: ["expansion": discoverActivityPanelExpansion == .expanded ? "expanded" : "compact"],
            updateLastActive: false
        )
    }

    /// True first-Discover introduction for guests and signed-in users (separate persistence keys).
    /// Does **not** mark intro complete until the user explicitly interacts.
    /// Starts fully collapsed (grabber only) — attention pulse on the handle; no expand→collapse flicker.
    private func presentDiscoverActivityPanelIntroIfNeeded() {
        // Post-signup Welcome dismiss may request intro; clear the flag either way.
        let postSignupPending = pendingDiscoverActivityPanelIntro
        if postSignupPending {
            pendingDiscoverActivityPanelIntro = false
        }

        guard isDiscoverTabSelected else { return }
        guard !viewModel.isVenueOwnerLoggedIn else { return }
        guard viewModel.isLoggedIn || viewModel.isGuestDiscoverMode else { return }
        guard !discoverActivityPanelIntroActive else { return }

        let persistenceUserId = discoverActivityPanelPersistenceUserId
        guard !FanGeoDiscoverActivityPanelPreferences.hasShownIntro(for: persistenceUserId) else { return }

        discoverActivityPanelIntroActive = true
        discoverActivityPanelShowIntroInstruction = true
        discoverActivityPanelUserInteracted = false
        discoverActivityPanelDidRestorePreference = true
        refreshDiscoverActivityCounts(reason: "intro")
        // Keep the panel fully collapsed; user expands via grabber when ready.
        discoverActivityPanelExpansion = .hidden
        FanGeoDiscoverActivityPanelPreferences.persistState(.hidden, for: persistenceUserId)
        fireDiscoverActivityHandleAttentionPulse()
        FanGeoAnalyticsService.record(
            eventName: "discover_activity_panel_intro_ready",
            sport: nil,
            metadata: ["source": postSignupPending ? "postSignupIntro" : "firstDiscoverIntro", "state": "hidden"],
            updateLastActive: false
        )
#if DEBUG
        print("[DiscoverActivityPanel] introPresented persistence=\(persistenceUserId == nil ? "guest" : "signedIn") state=hidden")
#endif
    }

    /// Marks intro complete only after explicit user interaction (collapse / hide / drag / tap / a11y).
    private func completeDiscoverActivityPanelIntroIfNeeded() {
        guard discoverActivityPanelIntroActive else { return }
        let persistenceUserId = discoverActivityPanelPersistenceUserId
        FanGeoDiscoverActivityPanelPreferences.markIntroShown(for: persistenceUserId)
        discoverActivityPanelIntroActive = false
        discoverActivityPanelShowIntroInstruction = false
#if DEBUG
        print("[DiscoverActivityPanel] introCompleted persistence=\(persistenceUserId == nil ? "guest" : "signedIn")")
#endif
    }

    private var reduceMotionCompatiblePanelAnimation: Animation {
        .spring(response: 0.32, dampingFraction: 0.86)
    }

    private func scheduleDiscoverActivityPanelAutoCollapse() {
        cancelDiscoverActivityPanelAutoCollapse()
        discoverActivityPanelAutoCollapseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            guard !discoverActivityPanelUserInteracted else { return }
            guard discoverActivityPanelExpansion == .expanded else { return }
            withAnimation(reduceMotionCompatiblePanelAnimation) {
                discoverActivityPanelExpansion = .compact
            }
            // Auto-collapse does NOT mark intro complete — user must interact.
            FanGeoDiscoverActivityPanelPreferences.persistState(
                .compact,
                for: discoverActivityPanelPersistenceUserId
            )
            FanGeoAnalyticsService.record(
                eventName: "discover_activity_panel_collapsed",
                sport: nil,
                metadata: ["source": "auto"],
                updateLastActive: false
            )
#if DEBUG
            print("[DiscoverActivityPanelPerf] state=compact")
#endif
        }
    }

    private func cancelDiscoverActivityPanelAutoCollapse() {
        discoverActivityPanelAutoCollapseTask?.cancel()
        discoverActivityPanelAutoCollapseTask = nil
    }

    private var discoverSearchAssistShowsClearRecent: Bool {
        viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !searchSuggestionController.recentSearches.isEmpty
    }

    private var discoverSearchAssistShowsFilterChips: Bool {
        guard isSearchFocused else { return false }
        let trimmed = viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return DiscoverSearchSuggestion.normalizedText(trimmed).count >= 2
    }

    @ViewBuilder
    private func discoverSearchAssistPanel(layoutHeight: CGFloat) -> some View {
        if isSearchFocused
            && (discoverSearchAssistShowsFilterChips
                || !discoverSearchAssistSections.isEmpty
                || discoverShouldShowSuggestionLoading
                || discoverShouldShowSuggestionEmpty) {
            let languageCode = L10n.normalizedLanguageCode(appLanguageRaw)
            let scrollMaxHeight = discoverSearchAssistScrollMaxHeight(layoutHeight: layoutHeight)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(
                        discoverShouldShowSuggestionEmpty
                            ? discoverSearchAssistEmptyTitle(languageCode: languageCode)
                            : (discoverShouldShowSuggestionLoading
                                ? L10n.t("discover_search_searching_fangeo", languageCode: languageCode)
                                : discoverSearchAssistTitle)
                    )
                        .font(FGTypography.caption.weight(.heavy))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .textCase(.uppercase)
                        .tracking(0.7)
                    Spacer(minLength: 0)
                    if discoverSearchAssistShowsClearRecent {
                        Button(L10n.t("discover_search_clear", languageCode: languageCode)) {
                            searchSuggestionController.clearRecentSearches()
                        }
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.accentBlue)
                    }
                    if discoverShouldShowSuggestionLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, FGSpacing.md)
                .padding(.top, 12)
                .padding(.bottom, discoverSearchAssistHeaderBottomPadding)

                if discoverSearchAssistShowsFilterChips {
                    discoverSearchFilterChipBar(languageCode: languageCode)
                }

                if discoverShouldShowSuggestionEmpty {
                    Text(discoverSearchAssistEmptySupporting(languageCode: languageCode))
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, FGSpacing.md)
                        .padding(.bottom, 12)
                } else if !discoverSearchAssistSections.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(discoverSearchAssistSections) { section in
                                // Recent searches already use the panel header ("Recent Searches" + Clear).
                                // Skip the duplicate in-list section title for that category only.
                                if section.category != .recent {
                                    Text(discoverSearchAssistSectionTitle(section.category, languageCode: languageCode))
                                        .font(FGTypography.caption.weight(.heavy))
                                        .foregroundStyle(FGColor.mutedText(colorScheme))
                                        .textCase(.uppercase)
                                        .tracking(0.5)
                                        .padding(.horizontal, FGSpacing.md)
                                        .padding(.top, 10)
                                        .padding(.bottom, 2)
                                        .accessibilityAddTraits(.isHeader)
                                }

                                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, suggestion in
                                    Button {
                                        selectDiscoverSearchSuggestion(suggestion)
                                    } label: {
                                        discoverSearchAssistRow(suggestion)
                                    }
                                    .buttonStyle(.plain)

                                    if index < section.rows.count - 1 {
                                        Divider()
                                            .padding(.leading, 50)
                                            .opacity(colorScheme == .dark ? 0.26 : 0.46)
                                    }
                                }
                            }
                        }
                        .padding(.top, discoverSearchAssistShowsClearRecent ? 2 : 0)
                        .padding(
                            .bottom,
                            discoverSearchAssistScrollContentBottomInset(scrollMaxHeight: scrollMaxHeight)
                        )
                    }
                    .frame(maxHeight: scrollMaxHeight)
                    .scrollDismissesKeyboard(.never)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .discoverLightGlassCard(cornerRadius: 20, style: .overlay)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .zIndex(4)
            .animation(.easeInOut(duration: 0.22), value: scrollMaxHeight)
        }
    }

    private func discoverSearchFilterChipBar(languageCode: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DiscoverSearchResultFilter.allCases) { filter in
                    discoverSearchFilterChip(filter, languageCode: languageCode)
                }
            }
            .padding(.horizontal, FGSpacing.md)
            .padding(.vertical, 2)
        }
        .frame(height: 36)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
    }

    private func discoverSearchFilterChip(
        _ filter: DiscoverSearchResultFilter,
        languageCode: String
    ) -> some View {
        let isSelected = discoverSearchResultFilter == filter
        let isSuggested = !isSelected
            && discoverSearchResultFilter == .all
            && discoverSearchSuggestedFilter == filter
        let tint = filter.tint
        let title = filter.title(languageCode: languageCode)

        return Button {
            guard discoverSearchResultFilter != filter else { return }
            FGInteractionHaptics.selection()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                discoverSearchResultFilter = filter
            }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(isSelected ? Color.white : FGColor.primaryText(colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background {
                    Capsule(style: .continuous)
                        .fill(isSelected ? AnyShapeStyle(tint) : AnyShapeStyle(Color(.tertiarySystemFill)))
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(
                            isSuggested ? tint.opacity(colorScheme == .dark ? 0.70 : 0.55) : Color.clear,
                            lineWidth: isSuggested ? 1.25 : 0
                        )
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            String(
                format: L10n.t("discover_search_filter_a11y_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                title
            )
        )
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint(
            isSuggested
                ? L10n.t("discover_search_filter_suggested_a11y_hint", languageCode: languageCode)
                : ""
        )
    }

    /// Soft cap so the assist panel never becomes an awkward full-screen sheet.
    /// ~35% taller than the prior 340pt cap so ~3–5 recent + ~3–5 live rows fit before scrolling.
    private static let discoverSearchAssistScrollHeightCap: CGFloat = 460
    private static let discoverSearchAssistScrollHeightFloor: CGFloat = 120
    /// Watch / Play unified dock height (`discoverUnifiedInfoToggleControl`).
    private static let discoverSearchAssistWatchPlayDockHeight: CGFloat = 66
    private static let discoverSearchAssistBottomBreathingRoom: CGFloat = 16

    /// Result viewport height: remaining space between header/chips and bottom obstacles (dock + keyboard).
    private func discoverSearchAssistScrollMaxHeight(layoutHeight: CGFloat) -> CGFloat {
        let topChrome =
            4 // top overlay padding
            + 52 // search bar
            + 6 // spacing under search
            + discoverSearchAssistPanelNonScrollHeight
        let bottomObstacle = discoverSearchAssistBottomObstacleHeight
        let available = layoutHeight - topChrome - bottomObstacle
        return min(
            Self.discoverSearchAssistScrollHeightCap,
            max(Self.discoverSearchAssistScrollHeightFloor, available)
        )
    }

    /// Header + optional filter chips inside the assist panel (excluded from the ScrollView).
    private var discoverSearchAssistPanelNonScrollHeight: CGFloat {
        let header: CGFloat = 12 + 18 + discoverSearchAssistHeaderBottomPadding
        let chips: CGFloat = discoverSearchAssistShowsFilterChips ? (36 + 8) : 0
        return header + chips
    }

    /// Bottom chrome the result list must clear: keyboard when open, otherwise Watch/Play dock + gap.
    private var discoverSearchAssistBottomObstacleHeight: CGFloat {
        let keyboard = discoverSearchKeyboardBottomOverlap
        if keyboard > 0 {
            // Keyboard covers tab bar / ad; keep a small gap above the keyboard top edge.
            return keyboard + Self.discoverSearchAssistBottomBreathingRoom
        }
        // Keyboard dismissed: Watch/Play dock overlays the lower map and can cover the last rows.
        return Self.discoverSearchAssistWatchPlayDockHeight
            + Self.discoverSearchAssistBottomBreathingRoom
            + 24 // modest clearance above the tab-bar spacer region
    }

    /// Extra scroll-content inset so the final row can rest fully above fixed bottom chrome.
    private func discoverSearchAssistScrollContentBottomInset(scrollMaxHeight: CGFloat) -> CGFloat {
        let breathing = Self.discoverSearchAssistBottomBreathingRoom
        if discoverSearchKeyboardBottomOverlap > 0 {
            // Viewport is already constrained above the keyboard.
            return breathing
        }
        // Soft height cap can leave the panel overlapping the Watch/Play dock — clear that overlap.
        if scrollMaxHeight >= Self.discoverSearchAssistScrollHeightCap - 0.5 {
            return Self.discoverSearchAssistWatchPlayDockHeight + breathing
        }
        return breathing
    }

    /// Slightly roomier gap under the panel header when Recent Searches is shown (no duplicate section title).
    private var discoverSearchAssistHeaderBottomPadding: CGFloat {
        if discoverSearchAssistShowsFilterChips { return 6 }
        if discoverSearchAssistSections.isEmpty { return 12 }
        if discoverSearchAssistShowsClearRecent { return 8 }
        return 4
    }

    private enum DiscoverSearchResultFilter: String, CaseIterable, Identifiable {
        case all
        case fans
        case watchSpots
        case pickup
        case proGames
        case teams

        var id: String { rawValue }

        func title(languageCode: String) -> String {
            switch self {
            case .all:
                return L10n.t("discover_search_filter_all", languageCode: languageCode)
            case .fans:
                return L10n.t("discover_search_filter_fans", languageCode: languageCode)
            case .watchSpots:
                return L10n.t("discover_search_filter_watch_spots", languageCode: languageCode)
            case .pickup:
                return L10n.t("discover_search_filter_pickup", languageCode: languageCode)
            case .proGames:
                return L10n.t("discover_search_filter_pro_games", languageCode: languageCode)
            case .teams:
                return L10n.t("discover_search_filter_teams", languageCode: languageCode)
            }
        }

        var tint: Color {
            switch self {
            case .all:
                return FGColor.accentBlueStrong
            case .fans:
                return Color.purple
            case .watchSpots:
                return FGColor.intentWatch
            case .pickup:
                return FGColor.intentPlay
            case .proGames:
                return FGColor.intentProGames
            case .teams:
                return FGColor.gradientEnd
            }
        }

        var allowedCategories: Set<DiscoverSearchAssistCategory>? {
            switch self {
            case .all:
                return nil
            case .fans:
                return [.fans]
            case .watchSpots:
                return [.venues, .places]
            case .pickup:
                return [.sports, .pickup]
            case .proGames:
                return [.proGames, .games, .competitions]
            case .teams:
                return [.teams, .competitions]
            }
        }
    }

    private enum DiscoverSearchAssistCategory: String, Identifiable {
        case proGames
        case fans
        case games
        case teams
        case competitions
        case sports
        case venues
        case places
        case pickup
        case recent

        var id: String { rawValue }
    }

    private struct DiscoverSearchAssistSection: Identifiable {
        let category: DiscoverSearchAssistCategory
        let rows: [DiscoverSearchSuggestion]

        var id: String { category.id }
    }

    /// Soft priority hint only — never permanently switches the selected chip.
    private var discoverSearchSuggestedFilter: DiscoverSearchResultFilter? {
        let trimmed = viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("@") { return .fans }
        let normalized = DiscoverSearchSuggestion.normalizedText(trimmed)
        if normalized.contains(" vs ") || normalized.contains(" v ") {
            return .proGames
        }
        return nil
    }

    /// Built outside row rendering; stable IDs; empty categories omitted; then chip-filtered.
    private var discoverSearchAssistSections: [DiscoverSearchAssistSection] {
        applyDiscoverSearchResultFilter(discoverSearchAssistSectionsUnfiltered)
    }

    private var discoverSearchAssistSectionsUnfiltered: [DiscoverSearchAssistSection] {
        let trimmed = viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSearchFocused else { return [] }
        if trimmed.isEmpty {
            let recent = searchSuggestionController.recentSearches
            guard !recent.isEmpty else { return [] }
            return [DiscoverSearchAssistSection(category: .recent, rows: recent)]
        }
        guard DiscoverSearchSuggestion.normalizedText(trimmed).count >= 2 else { return [] }

        let languageCode = L10n.normalizedLanguageCode(appLanguageRaw)
        let local = viewModel.discoverVenueEventSearchSuggestions(for: trimmed, languageCode: languageCode)
            .map(DiscoverSearchSuggestion.fromVenueEventSuggestion)

        var games: [DiscoverSearchSuggestion] = []
        var teams: [DiscoverSearchSuggestion] = []
        var competitions: [DiscoverSearchSuggestion] = []
        var sports: [DiscoverSearchSuggestion] = []
        for item in local {
            switch item.source {
            case .game: games.append(item)
            case .team: teams.append(item)
            case .league: competitions.append(item)
            case .sport: sports.append(item)
            default: break
            }
        }

        var seenVenueIDs = Set<UUID>()
        var venues: [DiscoverSearchSuggestion] = []
        for bar in viewModel.venueSearchResults.prefix(4) {
            guard seenVenueIDs.insert(bar.id).inserted else { continue }
            venues.append(DiscoverSearchSuggestion.fromVenueBar(bar, languageCode: languageCode))
        }

        var seenPlaceKeys = Set<String>()
        var places: [DiscoverSearchSuggestion] = []
        for suggestion in searchSuggestionController.suggestions.prefix(4) {
            let key = DiscoverSearchSuggestion.normalizedText("\(suggestion.title)|\(suggestion.subtitle)")
            guard seenPlaceKeys.insert(key).inserted else { continue }
            places.append(
                DiscoverSearchSuggestion(
                    title: suggestion.title,
                    subtitle: placeSuggestionSubtitle(for: suggestion, languageCode: languageCode),
                    latitude: suggestion.latitude,
                    longitude: suggestion.longitude,
                    source: suggestion.source,
                    kind: .city,
                    accessibilityLabelOverride: [
                        suggestion.title,
                        L10n.t("discover_search_kind_place", languageCode: languageCode)
                    ].joined(separator: ". ")
                )
            )
        }

        let fans = discoverFanSearchController.results.prefix(5).map {
            DiscoverSearchSuggestion.fromFan($0, languageCode: languageCode)
        }

        let proGames = discoverProGameSearchController.results.prefix(5).map {
            DiscoverSearchSuggestion.fromProGame($0, languageCode: languageCode)
        }

        var sections: [DiscoverSearchAssistSection] = []
        let preferFansFirst = discoverSearchSuggestedFilter == .fans
        if preferFansFirst, !fans.isEmpty {
            sections.append(DiscoverSearchAssistSection(category: .fans, rows: Array(fans)))
        }
        if !proGames.isEmpty {
            sections.append(DiscoverSearchAssistSection(category: .proGames, rows: Array(proGames)))
        }
        if !preferFansFirst, !fans.isEmpty {
            sections.append(DiscoverSearchAssistSection(category: .fans, rows: Array(fans)))
        }

        let caps: [(DiscoverSearchAssistCategory, [DiscoverSearchSuggestion], Int)] = [
            (.games, games, 4),
            (.teams, teams, 3),
            (.competitions, competitions, 3),
            (.sports, sports, 3),
            (.venues, venues, 4),
            (.places, places, 4)
        ]
        var total = 0
        let totalCap = 14
        for (category, rows, cap) in caps {
            guard !rows.isEmpty, total < totalCap else { continue }
            let sliced = Array(rows.prefix(min(cap, totalCap - total)))
            guard !sliced.isEmpty else { continue }
            sections.append(DiscoverSearchAssistSection(category: category, rows: sliced))
            total += sliced.count
        }
        return sections
    }

    private func applyDiscoverSearchResultFilter(
        _ sections: [DiscoverSearchAssistSection]
    ) -> [DiscoverSearchAssistSection] {
        guard let allowed = discoverSearchResultFilter.allowedCategories else {
            return sections
        }
        var filtered = sections.filter { allowed.contains($0.category) }
        if discoverSearchResultFilter == .pickup {
            let pickupRows = discoverPickupFilterSuggestions()
            if !pickupRows.isEmpty {
                filtered.append(DiscoverSearchAssistSection(category: .pickup, rows: pickupRows))
            }
        }
        return filtered
    }

    /// Client-side match over already-loaded pickup map rows — no new network work.
    private func discoverPickupFilterSuggestions() -> [DiscoverSearchSuggestion] {
        let trimmed = viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = DiscoverSearchSuggestion.normalizedText(trimmed)
        guard query.count >= 2 else { return [] }
        let languageCode = L10n.normalizedLanguageCode(appLanguageRaw)
        var rows: [DiscoverSearchSuggestion] = []

        for game in viewModel.pickupGamesForDiscoverMap.prefix(24) {
            let haystacks = [game.title, game.sport, game.city ?? "", game.address ?? ""]
                .map(DiscoverSearchSuggestion.normalizedText)
            guard haystacks.contains(where: { !$0.isEmpty && ($0 == query || $0.hasPrefix(query) || $0.contains(query)) }) else {
                continue
            }
            let subtitleParts = [game.sport, game.city ?? ""]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            rows.append(
                DiscoverSearchSuggestion(
                    title: game.title,
                    subtitle: subtitleParts.isEmpty
                        ? L10n.t("discover_search_filter_pickup", languageCode: languageCode)
                        : subtitleParts.joined(separator: " · "),
                    latitude: game.latitude,
                    longitude: game.longitude,
                    source: .game,
                    kind: .pickupPlace,
                    sportToken: "pickupGame:\(game.id.uuidString)",
                    accessibilityLabelOverride: [
                        game.title,
                        L10n.t("discover_search_filter_pickup", languageCode: languageCode)
                    ].joined(separator: ". ")
                )
            )
            if rows.count >= 4 { break }
        }

        if rows.count < 4 {
            for place in viewModel.pickupPlacesForDiscoverMap.prefix(24) {
                let haystacks = [place.name, place.city ?? "", place.state ?? "", place.sportTags.joined(separator: " ")]
                    .map(DiscoverSearchSuggestion.normalizedText)
                guard haystacks.contains(where: { !$0.isEmpty && ($0 == query || $0.hasPrefix(query) || $0.contains(query)) }) else {
                    continue
                }
                let location = [place.city, place.state]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: ", ")
                rows.append(
                    DiscoverSearchSuggestion(
                        title: place.name,
                        subtitle: location.isEmpty
                            ? L10n.t("discover_search_filter_pickup", languageCode: languageCode)
                            : location,
                        latitude: place.latitude,
                        longitude: place.longitude,
                        source: .place,
                        kind: .pickupPlace,
                        venueIDs: [place.id],
                        accessibilityLabelOverride: [
                            place.name,
                            L10n.t("discover_search_filter_pickup", languageCode: languageCode)
                        ].joined(separator: ". ")
                    )
                )
                if rows.count >= 4 { break }
            }
        }

        return rows
    }

    private var discoverSearchAssistRows: [DiscoverSearchSuggestion] {
        discoverSearchAssistSections.flatMap(\.rows)
    }

    private func discoverSearchAssistSectionTitle(
        _ category: DiscoverSearchAssistCategory,
        languageCode: String
    ) -> String {
        switch category {
        case .proGames:
            return L10n.t("Pro Games", languageCode: languageCode)
        case .fans:
            return L10n.t("discover_search_category_fans", languageCode: languageCode)
        case .games:
            return L10n.t("discover_search_category_games", languageCode: languageCode)
        case .teams:
            return L10n.t("discover_search_category_teams", languageCode: languageCode)
        case .competitions:
            return L10n.t("discover_search_category_competitions", languageCode: languageCode)
        case .sports:
            return L10n.t("discover_search_category_sports", languageCode: languageCode)
        case .venues:
            return L10n.t("discover_search_category_venues", languageCode: languageCode)
        case .places:
            return L10n.t("discover_search_category_places", languageCode: languageCode)
        case .pickup:
            return L10n.t("discover_search_filter_pickup", languageCode: languageCode)
        case .recent:
            return L10n.t("Recent Searches", languageCode: languageCode)
        }
    }

    private func placeSuggestionSubtitle(
        for suggestion: DiscoverSearchSuggestion,
        languageCode: String
    ) -> String {
        let existing = suggestion.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !existing.isEmpty { return existing }
        return L10n.t("discover_search_place_subtitle", languageCode: languageCode)
    }

    private var discoverShouldShowSuggestionLoading: Bool {
        let trimmed = viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryReady = isSearchFocused
            && DiscoverSearchSuggestion.normalizedText(trimmed).count >= 2
        guard queryReady, discoverSearchAssistRows.isEmpty else { return false }

        let placeLoading = searchSuggestionController.isLoading
            && searchSuggestionController.suggestions.isEmpty
        let fanLoading = discoverFanSearchController.isLoading
            && discoverFanSearchController.results.isEmpty
        let venueLoading = viewModel.isDiscoverVenueSearchLoading
            && viewModel.venueSearchResults.isEmpty

        switch discoverSearchResultFilter {
        case .all:
            return placeLoading || fanLoading
        case .fans:
            return fanLoading
        case .watchSpots:
            return placeLoading || venueLoading
        case .pickup, .teams:
            return false
        case .proGames:
            return discoverProGameSearchController.isLoading
                && discoverProGameSearchController.results.isEmpty
        }
    }

    private var discoverShouldShowSuggestionEmpty: Bool {
        let trimmed = viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSearchFocused,
              DiscoverSearchSuggestion.normalizedText(trimmed).count >= 2,
              !discoverShouldShowSuggestionLoading else { return false }

        switch discoverSearchResultFilter {
        case .all:
            return !searchSuggestionController.isLoading
                && !discoverFanSearchController.isLoading
                && !viewModel.isDiscoverVenueSearchLoading
                && discoverSearchAssistSections.isEmpty
        case .fans:
            return !discoverFanSearchController.isLoading
                && discoverSearchAssistSections.isEmpty
        case .watchSpots:
            return !searchSuggestionController.isLoading
                && !viewModel.isDiscoverVenueSearchLoading
                && discoverSearchAssistSections.isEmpty
        case .pickup, .teams:
            return discoverSearchAssistSections.isEmpty
        case .proGames:
            return !discoverProGameSearchController.isLoading
                && discoverSearchAssistSections.isEmpty
        }
    }

    private func discoverSearchAssistEmptyTitle(languageCode: String) -> String {
        switch discoverSearchResultFilter {
        case .all:
            return L10n.t("discover_search_no_results_title", languageCode: languageCode)
        case .fans:
            return L10n.t("discover_search_empty_fans", languageCode: languageCode)
        case .watchSpots:
            return L10n.t("discover_search_empty_watch_spots", languageCode: languageCode)
        case .pickup:
            return L10n.t("discover_search_empty_pickup", languageCode: languageCode)
        case .proGames:
            return L10n.t("discover_search_empty_pro_games", languageCode: languageCode)
        case .teams:
            return L10n.t("discover_search_empty_teams", languageCode: languageCode)
        }
    }

    private func discoverSearchAssistEmptySupporting(languageCode: String) -> String {
        switch discoverSearchResultFilter {
        case .all:
            return L10n.t("discover_search_no_results_supporting", languageCode: languageCode)
        case .fans, .watchSpots, .pickup, .proGames, .teams:
            return L10n.t("discover_search_empty_filter_supporting", languageCode: languageCode)
        }
    }

    private var discoverSearchAssistTitle: String {
        let trimmed = viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let languageCode = L10n.normalizedLanguageCode(appLanguageRaw)
        if trimmed.isEmpty {
            return L10n.t("Recent Searches", languageCode: languageCode)
        }
        return L10n.t("discover_search_suggestions_title", languageCode: languageCode)
    }

    private func discoverSearchAssistRow(_ suggestion: DiscoverSearchSuggestion) -> some View {
        HStack(spacing: FGSpacing.sm) {
            discoverSearchAssistLeadingVisual(for: suggestion)

            VStack(alignment: .leading, spacing: 3) {
                Text(suggestion.title)
                    .font(FGTypography.cardTitle.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(1)

                if !suggestion.subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(suggestion.subtitle)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                } else if suggestion.source == .recent {
                    Text("Recent search")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: suggestion.source == .fan || suggestion.kind == .fan
                  ? "person.crop.circle"
                  : (suggestion.source == .proGame || suggestion.kind == .proGame
                     ? "sportscourt"
                     : "arrow.up.left"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(suggestion.accessibilityLabelOverride ?? suggestion.title)
        .accessibilityHint(discoverSearchSuggestionAccessibilityHint(for: suggestion))
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private func discoverSearchAssistLeadingVisual(for suggestion: DiscoverSearchSuggestion) -> some View {
        if suggestion.source == .fan || suggestion.kind == .fan {
            let preview = UserPreview(
                id: suggestion.fanUserId ?? UUID(),
                displayName: suggestion.title,
                avatarURL: suggestion.fanAvatarURL,
                avatarThumbnailURL: suggestion.fanAvatarURL
            )
            SocialAvatarRenderer.socialAvatarView(for: preview, size: 44)
                .frame(width: 44, height: 44)
                .background(Circle().fill(FGColor.cardBackground(colorScheme)))
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                }
                .accessibilityHidden(true)
        } else if suggestion.source == .proGame || suggestion.kind == .proGame,
                  let match = resolveDiscoverProGameMatch(for: suggestion) {
            discoverProGameCrestPair(for: match)
                .accessibilityHidden(true)
        } else {
            Image(systemName: discoverSearchSuggestionIcon(for: suggestion))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(suggestion.source == .recent ? FGColor.mutedText(colorScheme) : FGColor.accentBlue)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
                .background {
                    Circle()
                        .fill((suggestion.source == .recent ? FGColor.mutedText(colorScheme) : FGColor.accentBlue).opacity(colorScheme == .dark ? 0.18 : 0.11))
                }
        }
    }

    /// Crest priority: both displayable crests → pair; one → that crest alone;
    /// none → ONE league/sport icon. Never renders two generic placeholder shields.
    /// (Club logos resolve to `.none` unless verified licensed, so the sport icon
    /// is the common displayable fallback for pro clubs.)
    private func discoverProGameCrestPair(for match: LiveMatch) -> some View {
        let homeIdentity = ProGameTeamScoreIdentity.resolve(
            teamName: match.homeTeam,
            badgeURL: match.homeTeamBadgeURL,
            source: "DiscoverSearch"
        )
        let awayIdentity = ProGameTeamScoreIdentity.resolve(
            teamName: match.awayTeam,
            badgeURL: match.awayTeamBadgeURL,
            source: "DiscoverSearch"
        )
        let sportVisual = discoverProGameSportVisual(for: match)
        return HStack(spacing: -6) {
            if homeIdentity.leading == .none, awayIdentity.leading == .none {
                discoverProGameSportFallbackCircle(sportVisual)
            } else {
                if homeIdentity.leading != .none {
                    discoverProGameCrest(identity: homeIdentity, sportVisual: sportVisual)
                }
                if awayIdentity.leading != .none {
                    discoverProGameCrest(identity: awayIdentity, sportVisual: sportVisual)
                }
            }
        }
        .frame(width: 44, height: 30, alignment: .leading)
    }

    /// Sport icon for a pro game (MLB → baseball, NBA → basketball, …), preferring
    /// the sport string and falling back to the league name for canonical mapping.
    private func discoverProGameSportVisual(for match: LiveMatch) -> SportFilterCatalog.ChipVisual {
        let sportRaw = match.sport.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sportRaw.isEmpty, !SportFilterCatalog.isFallbackSport(sportRaw) {
            return SportFilterCatalog.resolve(sportRaw)
        }
        let leagueRaw = match.league.trimmingCharacters(in: .whitespacesAndNewlines)
        if !leagueRaw.isEmpty, !SportFilterCatalog.isFallbackSport(leagueRaw) {
            return SportFilterCatalog.resolve(leagueRaw)
        }
        return SportFilterCatalog.fallback
    }

    private func discoverProGameSportFallbackCircle(_ visual: SportFilterCatalog.ChipVisual) -> some View {
        Image(systemName: visual.systemImage)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(visual.accent)
            .frame(width: 26, height: 26)
            .background {
                Circle()
                    .fill(visual.accent.opacity(colorScheme == .dark ? 0.22 : 0.13))
            }
            .overlay {
                Circle()
                    .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
            }
    }

    @ViewBuilder
    private func discoverProGameCrest(
        identity: ProGameTeamScoreIdentity,
        sportVisual: SportFilterCatalog.ChipVisual
    ) -> some View {
        Group {
            switch identity.leading {
            case .logoURL(let url):
                DiscoverCachedRemoteImage(url: url, contentMode: .fit) {
                    // Loading/failure placeholder: sport icon, not a generic shield.
                    Image(systemName: sportVisual.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(sportVisual.accent)
                }
            case .flag(let flag):
                Text(flag)
                    .font(.system(size: 14))
            case .none:
                Image(systemName: sportVisual.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(sportVisual.accent)
            }
        }
        .frame(width: 26, height: 26)
        .background(Circle().fill(FGColor.cardBackground(colorScheme)))
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
    }

    private func resolveDiscoverProGameMatch(for suggestion: DiscoverSearchSuggestion) -> LiveMatch? {
        guard let key = suggestion.proGameStableKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        if let cached = discoverProGameSearchController.match(forStableKey: key) {
            return cached
        }
        return viewModel.liveMatches.first(where: { SavedProGame.stableKey(for: $0) == key })
    }

    private func discoverSearchSuggestionAccessibilityHint(for suggestion: DiscoverSearchSuggestion) -> String {
        let languageCode = L10n.normalizedLanguageCode(appLanguageRaw)
        switch suggestion.source {
        case .proGame:
            return L10n.t("discover_search_pro_game_result_hint", languageCode: languageCode)
        case .game, .league, .team:
            return L10n.t("discover_search_game_result_hint", languageCode: languageCode)
        case .sport:
            return L10n.t("discover_search_sport_result_hint", languageCode: languageCode)
        case .venue:
            return L10n.t("discover_search_venue_result_hint", languageCode: languageCode)
        case .fan:
            return L10n.t("discover_search_fan_result_hint", languageCode: languageCode)
        case .city, .place, .recent:
            if suggestion.kind == .fan {
                return L10n.t("discover_search_fan_result_hint", languageCode: languageCode)
            }
            if suggestion.kind == .proGame {
                return L10n.t("discover_search_pro_game_result_hint", languageCode: languageCode)
            }
            return ""
        }
    }

    private func discoverSearchSuggestionIcon(for suggestion: DiscoverSearchSuggestion) -> String {
        switch suggestion.source {
        case .recent:
            return suggestion.displayKind.iconSystemName
        case .city:
            return "mappin.and.ellipse"
        case .place:
            return "location.circle"
        case .game:
            return DiscoverRecentSearchKind.game.iconSystemName
        case .team:
            return DiscoverRecentSearchKind.team.iconSystemName
        case .sport:
            return DiscoverRecentSearchKind.sport.iconSystemName
        case .league:
            return DiscoverRecentSearchKind.league.iconSystemName
        case .venue:
            return DiscoverRecentSearchKind.venue.iconSystemName
        case .fan:
            return DiscoverRecentSearchKind.fan.iconSystemName
        case .proGame:
            return DiscoverRecentSearchKind.proGame.iconSystemName
        }
    }

    private var discoverIntegratedLocationButton: some View {
        Button {
            discoverCenterMapOnUserLocation()
        } label: {
            Image(systemName: "location.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(FGColor.accentBlue)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.19 : 0.34))
                )
        }
        .buttonStyle(DiscoverIntegratedLocationButtonStyle())
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .accessibilityLabel("Center map on your location")
    }

    private static let discoverLocationDisabledHint =
        "Location is turned off. You can enable it in Settings ▸ Privacy & Security ▸ Location Services ▸ FanGeo. The map still shows a default area you can pan and search."

    private func discoverCenterMapOnUserLocation() {
        Task { @MainActor in
#if DEBUG
            print("[CurrentLocationButton] tapped")
#endif
            dismissDiscoverSearchKeyboard()
            let status = CLLocationManager().authorizationStatus
#if DEBUG
            print("[CurrentLocationButton] permission=\(discoverLocationAuthStatusLabel(status))")
#endif
            if status == .denied || status == .restricted {
                discoverLocationHint = Self.discoverLocationDisabledHint
                return
            }
            discoverLocationHint = nil
            let centered = await viewModel.centerDiscoverMapOnUserPhysicalLocationIfPossible()
            if centered {
                scheduleDiscoverWeatherRefresh(force: false)
            } else {
                discoverLocationHint = Self.discoverLocationDisabledHint
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                discoverMapLocationAuthVersion += 1
            }
        }
    }

    private var discoverSportsFilterGlassCard: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                discoverDateFilterChip
                DiscoverOverlaySportPillRow(
                    viewModel: viewModel,
                    showMoreSheet: $showDiscoverSportMoreSheet,
                    onSelect: { selection in
                        discoverSelectSport(selection)
                    }
                )
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .discoverLightGlassCard(cornerRadius: 19, style: .sportsRow)
        .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
    }

    @ViewBuilder
    private var pickupSubModeToggleIfNeeded: some View {
        if viewModel.discoverMapContentMode == .pickupGames {
            HStack(spacing: 6) {
                ForEach(DiscoverPickupSubMode.allCases) { mode in
                    let isSelected = viewModel.discoverPickupSubMode == mode
                    Button {
                        guard viewModel.discoverPickupSubMode != mode else { return }
                        FGInteractionHaptics.selection()
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            viewModel.discoverPickupSubMode = mode
                        }
                    } label: {
                        Text(mode.title)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(isSelected ? Color.white : Color.orange.opacity(0.96))
                            .padding(.horizontal, 14)
                            .frame(height: 30)
                            .background {
                                Capsule(style: .continuous)
                                    .fill(isSelected ? Color.orange.opacity(0.94) : Color.white.opacity(colorScheme == .dark ? 0.10 : 0.42))
                            }
                            .overlay {
                                Capsule(style: .continuous)
                                    .strokeBorder(Color.orange.opacity(isSelected ? 0.20 : 0.38), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .discoverLightGlassCard(cornerRadius: 18, style: .sportsRow)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    @ViewBuilder
    private var discoverWeatherPill: some View {
        if let discoverWeather {
            discoverWeatherTemperatureChip(discoverWeather.weather)
        }
    }

    private func discoverWeatherTemperatureChip(_ weather: DiscoverWeather) -> some View {
        HStack(spacing: 6) {
            Image(systemName: weather.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.orange)
                .symbolRenderingMode(.multicolor)
            Text("\(weather.temperature)°F")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .discoverLightGlassCard(cornerRadius: 15, style: .weather)
        .frame(minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityLabel("Weather \(weather.temperature) degrees")
    }

    private var discoverMapCenterCoordinate: CLLocationCoordinate2D? {
        viewModel.cameraPosition.region?.center
    }

    private enum DiscoverWeatherCoordinateBasis {
        case userLocation
        case mapCenterFallback
    }

    private func scheduleDiscoverWeatherRefresh(force: Bool) {
        discoverWeatherRefreshTask?.cancel()
        discoverWeatherRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }

            if force || viewModel.currentUserLocation == nil {
                _ = await viewModel.refreshCurrentUserLocationIfAuthorized()
            }

            let mapCenter = discoverMapCenterCoordinate
            guard let decision = resolveDiscoverWeatherCoordinate(mapCenter: mapCenter) else {
                discoverWeather = nil
                return
            }

            discoverLogWeatherRequest(decision, mapCenter: mapCenter)

            let snapshot = await DiscoverWeatherService.shared.weather(
                for: decision.coordinate,
                force: force,
                requestedBasis: decision.requestedBasisLabel
            )
            guard !Task.isCancelled else { return }

            discoverLogWeatherResult(decision, mapCenter: mapCenter, snapshot: snapshot)

            if let snapshot {
                discoverWeather = snapshot
            } else {
                discoverWeather = nil
            }
        }
    }

    private func resolveDiscoverWeatherCoordinate(
        mapCenter: CLLocationCoordinate2D?
    ) -> DiscoverWeatherCoordinateDecision? {
        let userCoordinate = viewModel.currentUserLocation
        let userAvailable = userCoordinate.map { CLLocationCoordinate2DIsValid($0) } ?? false

        let validMapCenter = mapCenter.flatMap { center -> CLLocationCoordinate2D? in
            CLLocationCoordinate2DIsValid(center) ? center : nil
        }

        if userAvailable, let userCoordinate {
            return DiscoverWeatherCoordinateDecision(
                coordinate: userCoordinate,
                basis: .userLocation,
                requestedBasis: .userLocation
            )
        }

        if let validMapCenter {
            return DiscoverWeatherCoordinateDecision(
                coordinate: validMapCenter,
                basis: .mapCenterFallback,
                requestedBasis: .mapCenterFallback
            )
        }

        return nil
    }

    private func discoverLogWeatherRequest(
        _ decision: DiscoverWeatherCoordinateDecision,
        mapCenter: CLLocationCoordinate2D?
    ) {
#if DEBUG
        print("[DiscoverWeatherDebug] requestedBasis=\(decision.requestedBasisLabel)")
        if let user = viewModel.currentUserLocation, CLLocationCoordinate2DIsValid(user) {
            print(String(format: "[DiscoverWeatherDebug] userLocationLat=%.4f", user.latitude))
            print(String(format: "[DiscoverWeatherDebug] userLocationLon=%.4f", user.longitude))
        } else {
            print("[DiscoverWeatherDebug] userLocationLat=nil")
            print("[DiscoverWeatherDebug] userLocationLon=nil")
        }
        if let mapCenter, CLLocationCoordinate2DIsValid(mapCenter) {
            print(String(format: "[DiscoverWeatherDebug] mapCenterLat=%.4f", mapCenter.latitude))
            print(String(format: "[DiscoverWeatherDebug] mapCenterLon=%.4f", mapCenter.longitude))
        } else {
            print("[DiscoverWeatherDebug] mapCenterLat=nil")
            print("[DiscoverWeatherDebug] mapCenterLon=nil")
        }
#endif
    }

    private func discoverLogWeatherResult(
        _ decision: DiscoverWeatherCoordinateDecision,
        mapCenter: CLLocationCoordinate2D?,
        snapshot: DiscoverWeatherSnapshot?
    ) {
#if DEBUG
        _ = mapCenter
        print("[DiscoverWeatherDebug] finalBasis=\(decision.basisLabel)")
        print("[DiscoverWeatherDebug] temp=\(snapshot.map { String($0.weather.temperature) } ?? "nil")")
        let sourceLabel: String = {
            guard let snapshot else { return "nil" }
            switch snapshot.source {
            case .weatherKit: return "weatherkit"
            case .openMeteo: return "open-meteo"
            }
        }()
        print("[DiscoverWeatherDebug] source=\(sourceLabel)")
#endif
    }

    private struct DiscoverWeatherCoordinateDecision {
        let coordinate: CLLocationCoordinate2D
        let basis: DiscoverWeatherCoordinateBasis
        let requestedBasis: DiscoverWeatherCoordinateBasis

        var requestedBasisLabel: String {
            switch requestedBasis {
            case .userLocation: return "user_location"
            case .mapCenterFallback: return "map_center_fallback"
            }
        }

        var basisLabel: String {
            switch basis {
            case .userLocation: return "user_location"
            case .mapCenterFallback: return "map_center_fallback"
            }
        }
    }

    @ViewBuilder
    private var discoverMapDisplayModeToggleCluster: some View {
        if viewModel.discoverMapContentMode == .venues {
            HStack(spacing: 8) {
                if let mapDisplayModeHintText {
                    Text(mapDisplayModeHintText)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background {
                            Capsule(style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay {
                                    Capsule(style: .continuous)
                                        .fill(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.50))
                                }
                        }
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    colorScheme == .dark ? Color.white.opacity(0.18) : FGColor.divider(colorScheme),
                                    lineWidth: 1
                                )
                        }
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.14 : 0.08), radius: 6, y: 2)
                        .transition(.opacity.combined(with: .move(edge: .trailing).combined(with: .scale(scale: 0.94))))
                }

                discoverMapDisplayModeToggleButton
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: mapDisplayModeHintText)
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: viewModel.mapDisplayMode)
        }
    }

    private var discoverMapDisplayModeToggleButton: some View {
        let isGamesOnly = viewModel.mapDisplayMode == .gamesOnly
        let iconName = isGamesOnly ? "sportscourt.fill" : "mappin.and.ellipse"

        return Button {
            cycleDiscoverMapDisplayMode()
        } label: {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isGamesOnly ? Color.white : FGColor.secondaryText(colorScheme))
                .frame(width: 36, height: 36)
                .background {
                    if isGamesOnly {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [FGColor.accentBlue, FGColor.accentGreen.opacity(0.92)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    } else {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .overlay {
                                Circle()
                                    .fill(Color.white.opacity(colorScheme == .dark ? 0.36 : 0.42))
                            }
                    }
                }
                .overlay {
                    Circle()
                        .strokeBorder(
                            isGamesOnly
                                ? Color.white.opacity(colorScheme == .dark ? 0.22 : 0.30)
                                : (colorScheme == .dark ? Color.white.opacity(0.14) : FGColor.divider(colorScheme)),
                            lineWidth: 1
                        )
                }
                .shadow(
                    color: isGamesOnly
                        ? FGColor.accentBlue.opacity(colorScheme == .dark ? 0.28 : 0.18)
                        : Color.black.opacity(colorScheme == .dark ? 0.11 : 0.08),
                    radius: isGamesOnly ? 6 : 5,
                    y: 1.5
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(viewModel.mapDisplayMode.title)
        .accessibilityHint("Double tap to switch map display mode")
    }

    private func cycleDiscoverMapDisplayMode() {
        dismissDiscoverSearchKeyboard()
        FGInteractionHaptics.softImpact()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            viewModel.mapDisplayMode = viewModel.mapDisplayMode.toggled
        }
        showMapDisplayModeHint(viewModel.mapDisplayMode.title)
    }

    private func showMapDisplayModeHint(_ text: String) {
        mapDisplayModeHintTask?.cancel()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            mapDisplayModeHintText = text
        }
        mapDisplayModeHintTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.22)) {
                    mapDisplayModeHintText = nil
                }
            }
        }
    }

    @ViewBuilder
    private var discoverBottomLeadingCard: some View {
        if let selectedBar = viewModel.selectedBar {
            if viewModel.canViewDiscoverDetails() || viewModel.isGuestDiscoverMode {
                venuePreviewCard(selectedBar)
                    // Stable identity so overlay rebuilds (e.g. activity panel) don’t remount
                    // the entire opaque preview type as a new recursive construction.
                    .id(selectedBar.id)
            } else {
                loggedOutVenueTeaserCard(selectedBar)
                    .id(selectedBar.id)
            }
        } else if let pickup = viewModel.selectedPickupGameForMap {
            discoverPickupPreviewCard(pickup, guestMapsActionsToLogin: viewModel.isGuestDiscoverMode) {
                pickupGameDetailNav = PickupDetailNavigationToken(id: pickup.id)
            }
            .id(pickup.id)
            .transition(
                .asymmetric(
                    insertion: .scale(scale: 0.94, anchor: .leading).combined(with: .opacity),
                    removal: .opacity
                )
            )
        } else if let place = viewModel.selectedPickupPlaceForMap {
            discoverPickupPlacePreviewCard(place)
                .id(place.id)
                .transition(
                    .asymmetric(
                        insertion: .scale(scale: 0.94, anchor: .leading).combined(with: .opacity),
                        removal: .opacity
                    )
                )
        }
    }

    private func discoverSelectSport(_ selection: String) {
        guard !DiscoverSportFilterRowLayout.selectionTokensMatch(viewModel.selectedSport, selection) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        let previousSport = viewModel.selectedSport
        let previousContextual = viewModel.mapDisplayMode
        let selectingAllSports = DiscoverSportFilterRowLayout.selectionTokensMatch(selection, "All")
        let previousWasAllSports = DiscoverSportFilterRowLayout.selectionTokensMatch(previousSport, "All")
        let shouldAutoSwitchToHostingGames =
            viewModel.discoverMapContentMode == .venues
            && previousContextual == .allSpots
            && previousWasAllSports
            && !selectingAllSports

        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            if shouldAutoSwitchToHostingGames {
                viewModel.mapDisplayMode = .gamesOnly
            }
            viewModel.sportChanged(to: selection)
        }

#if DEBUG
        print(
            "[DiscoverFilterIntent] previousSport=\(previousSport) selectedSport=\(selection) previousContextual=\(previousContextual.rawValue) resultingContextual=\(viewModel.mapDisplayMode.rawValue) source=explicitSportTap autoSwitch=\(shouldAutoSwitchToHostingGames)"
        )
#endif

        if shouldAutoSwitchToHostingGames {
            let sportLabel = discoverFriendlySportLabel(for: selection)
            let announcement = sportLabel.isEmpty
                ? L10n.t(
                    "discover_a11y_hosting_games_selected",
                    languageCode: L10n.normalizedLanguageCode(appLanguageRaw)
                )
                : String(
                    format: L10n.t(
                        "discover_a11y_sport_hosting_games_format",
                        languageCode: L10n.normalizedLanguageCode(appLanguageRaw)
                    ),
                    locale: Locale(identifier: L10n.normalizedLanguageCode(appLanguageRaw)),
                    sportLabel
                )
            AccessibilityNotification.Announcement(announcement).post()
        }
    }

    private func discoverFriendlySportLabel(for token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "All" { return "" }
        switch trimmed {
        case "NBA": return "Basketball"
        case "NFL": return "Football"
        case "NHL": return "Hockey"
        case "MLB": return "Baseball"
        default:
            if let pair = AppSportCatalog.discoverMapDefaultPopularPairs.first(where: { $0.0 == trimmed }) {
                return pair.1
            }
            return trimmed
        }
    }

    private var discoverUnifiedStatusSuggestsZoomOut: Bool {
        if discoverSummaryLoadingFeedbackVisible { return false }
        // Prefer explicit zero-result dock copy over a generic zoom hint when the empty card is visible.

        if viewModel.discoverMapContentMode == .venues {
            guard discoverSummaryVenueCount == 0 else { return false }
            let sportFiltered = viewModel.selectedSport.trimmingCharacters(in: .whitespacesAndNewlines) != "All"
            let searchActive = !viewModel.effectiveDiscoverSearchQuery
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            guard sportFiltered || searchActive else { return false }
            return viewModel.visibleBarCountInCurrentMapRegion() > 0
        }

        if isPickupPlacesMode {
            let allPlaces = viewModel.pickupPlacesForDiscoverMap
            guard viewModel.discoverVisiblePickupPlaceCount == 0, !allPlaces.isEmpty else { return false }
        } else {
            let bounds = viewModel.currentMapRegionBounds()
            let allPickupPins = viewModel.pickupGamesVisibleAsMapPins(for: bounds)
            let matchingPickupPins = discoverPickupPinsInBoundsMatchingSearch
            guard matchingPickupPins == 0, !allPickupPins.isEmpty else { return false }
        }
        let sportFiltered = viewModel.selectedSport.trimmingCharacters(in: .whitespacesAndNewlines) != "All"
        let searchActive = !viewModel.effectiveDiscoverSearchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        return sportFiltered || searchActive
    }

    private func discoverStatusSportDescriptor() -> String? {
        let label = discoverFriendlySportLabel(for: viewModel.selectedSport)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }
        return label.lowercased()
    }

    /// Capitalized sport label for Watch Hosting Games status/empty copy (e.g. "Soccer").
    private func discoverStatusSportDisplayName() -> String? {
        let label = discoverFriendlySportLabel(for: viewModel.selectedSport)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }
        return label
    }

    private var discoverUnifiedStatusText: String {
        let languageCode = L10n.normalizedLanguageCode(appLanguageRaw)
        if let filterStatus = viewModel.discoverSearchFilterStatusText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !filterStatus.isEmpty {
            return filterStatus
        }
        // Keep dock counts readable while the transient map toast explains refresh.
        // Only use "Looking for…" in the dock when there are no visible results yet.
        if discoverSummaryLoadingFeedbackVisible {
            let hasVisibleResults: Bool = {
                switch viewModel.discoverMapContentMode {
                case .pickupGames:
                    if isPickupPlacesMode {
                        return !viewModel.pickupPlacesVisibleAsMapPins(for: viewModel.currentMapRegionBounds()).isEmpty
                    }
                    return discoverPickupPinsInBoundsMatchingSearch > 0
                case .venues:
                    return discoverSummaryVenueCount > 0
                }
            }()
            if !hasVisibleResults {
                return viewModel.discoverMapRefreshLookingToastText()
            }
        }
        if discoverUnifiedStatusSuggestsZoomOut {
            return L10n.t("discover_status_try_zooming_out", languageCode: languageCode)
        }

        if viewModel.discoverMapContentMode == .pickupGames {
            if isPickupPlacesMode {
                let count = viewModel.discoverVisiblePickupPlaceCount
                if count > 0 {
                    if let sport = discoverStatusSportDescriptor() {
                        return count == 1
                            ? String(format: L10n.t("discover_status_sport_place_one_format", languageCode: languageCode), locale: Locale(identifier: languageCode), sport)
                            : String(format: L10n.t("discover_status_sport_place_other_format", languageCode: languageCode), locale: Locale(identifier: languageCode), count, sport)
                    }
                    return count == 1
                        ? L10n.t("discover_status_pickup_place_one", languageCode: languageCode)
                        : String(format: L10n.t("discover_status_pickup_place_other_format", languageCode: languageCode), locale: Locale(identifier: languageCode), count)
                }
                return L10n.t("discover_status_no_pickup_places", languageCode: languageCode)
            }
            let count = discoverPickupPinsInBoundsMatchingSearch
            if count > 0 {
                if let sport = discoverStatusSportDescriptor() {
                    return count == 1
                        ? String(format: L10n.t("discover_status_sport_pickup_one_format", languageCode: languageCode), locale: Locale(identifier: languageCode), sport)
                        : String(format: L10n.t("discover_status_sport_pickup_other_format", languageCode: languageCode), locale: Locale(identifier: languageCode), count, sport)
                }
                return count == 1
                    ? L10n.t("discover_status_pickup_game_one", languageCode: languageCode)
                    : String(format: L10n.t("discover_status_pickup_game_other_format", languageCode: languageCode), locale: Locale(identifier: languageCode), count)
            }
            return L10n.t("discover_status_no_pickup_games", languageCode: languageCode)
        }

        let count = discoverSummaryVenueCount
        if count > 0 {
            if viewModel.mapDisplayMode == .gamesOnly {
                if let sport = discoverStatusSportDisplayName() {
                    return count == 1
                        ? String(format: L10n.t("discover_status_hosting_sport_one_format", languageCode: languageCode), locale: Locale(identifier: languageCode), sport)
                        : String(format: L10n.t("discover_status_hosting_sport_other_format", languageCode: languageCode), locale: Locale(identifier: languageCode), count, sport)
                }
                return count == 1
                    ? L10n.t("discover_status_hosting_one", languageCode: languageCode)
                    : String(format: L10n.t("discover_status_hosting_other_format", languageCode: languageCode), locale: Locale(identifier: languageCode), count)
            }
            if let sport = discoverStatusSportDescriptor() {
                return count == 1
                    ? String(format: L10n.t("discover_status_sport_spot_one_format", languageCode: languageCode), locale: Locale(identifier: languageCode), sport)
                    : String(format: L10n.t("discover_status_sport_spot_other_format", languageCode: languageCode), locale: Locale(identifier: languageCode), count, sport)
            }
            return count == 1
                ? L10n.t("discover_status_watch_spot_one", languageCode: languageCode)
                : String(format: L10n.t("discover_status_watch_spot_other_format", languageCode: languageCode), locale: Locale(identifier: languageCode), count)
        }
        if viewModel.mapDisplayMode == .gamesOnly {
            if let sport = discoverStatusSportDisplayName() {
                return String(
                    format: L10n.t("discover_status_no_hosting_sport_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    sport
                )
            }
            return L10n.t("discover_status_no_hosting", languageCode: languageCode)
        }
        return L10n.t("discover_status_no_watch_spots", languageCode: languageCode)
    }

    private var discoverDateFilterChip: some View {
        Button {
            openDiscoverDatePicker()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                Text(viewModel.formattedSelectedDate)
                if viewModel.isUpdatingMapGames {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(height: 36)
            .background(FGColor.brandGradient.opacity(colorScheme == .dark ? 0.88 : 0.90))
            .clipShape(Capsule(style: .continuous))
            .shadow(color: FGColor.gradientEnd.opacity(0.12), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
    }

    private func dismissDiscoverSearchKeyboard() {
        isSearchFocused = false
        discoverSearchResultFilter = .all
        searchSuggestionController.clearSuggestions()
        discoverFanSearchController.clear()
        discoverProGameSearchController.clear()
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func refreshDiscoverSearchSuggestions() {
        searchSuggestionController.refresh(
            query: viewModel.searchText,
            isFocused: isSearchFocused,
            region: viewModel.cameraPosition.region
        )
        discoverFanSearchController.refresh(
            query: viewModel.searchText,
            isAuthenticated: viewModel.isAuthenticatedForSocialFeatures,
            isFocused: isSearchFocused
        )
        discoverProGameSearchController.refresh(
            query: viewModel.searchText,
            inventory: viewModel.liveMatches,
            isFocused: isSearchFocused,
            favoriteTeamIDs: FavoriteTeamsStore.decodeIDs(from: discoverFavoriteTeamIDsRaw)
        )
    }

    private func selectDiscoverSearchSuggestion(_ suggestion: DiscoverSearchSuggestion) {
        let query = suggestion.displayQuery
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || suggestion.source == .fan
                || suggestion.kind == .fan else { return }

        let resolvedKind = suggestion.kind ?? suggestion.displayKind

        if resolvedKind == .pickupPlace
            || suggestion.sportToken?.hasPrefix("pickupGame:") == true {
            if selectDiscoverPickupSearchSuggestion(suggestion) {
                return
            }
        }

        if suggestion.source == .fan || resolvedKind == .fan {
            guard let fanUserId = suggestion.fanUserId else { return }
            searchSuggestionController.remember(suggestion)
            searchSuggestionController.clearSuggestions()
            discoverFanSearchController.clear()
            discoverProGameSearchController.clear()
            dismissDiscoverSearchKeyboard()
            viewModel.presentPublicProfile(userId: fanUserId, context: "discover_search")
            return
        }

        if suggestion.source == .proGame || resolvedKind == .proGame {
            guard let match = resolveDiscoverProGameMatch(for: suggestion) else { return }
            searchSuggestionController.remember(suggestion)
            searchSuggestionController.clearSuggestions()
            discoverFanSearchController.clear()
            discoverProGameSearchController.clear()
            dismissDiscoverSearchKeyboard()
            viewModel.setDiscoverFocusedProGame(from: match, alignSelectedDate: true)
            discoverProGameDetailMatch = match
            return
        }

        let isVenueEventSelection =
            suggestion.source == .game
            || suggestion.source == .team
            || suggestion.source == .sport
            || suggestion.source == .league
            || (suggestion.source == .recent && (resolvedKind == .game || resolvedKind == .team || resolvedKind == .sport || resolvedKind == .league))

        if suggestion.source == .venue {
            searchSuggestionController.remember(suggestion)
            searchSuggestionController.clearSuggestions()
            dismissDiscoverSearchKeyboard()
            if let venueID = suggestion.venueIDs?.first,
               let bar = viewModel.bars.first(where: { $0.id == venueID })
                ?? viewModel.venueSearchResults.first(where: { $0.id == venueID }) {
                withAnimation(.spring()) {
                    viewModel.selectVenueFromDiscoverSearchResult(bar)
                }
            }
            return
        }

        searchSuggestionController.remember(suggestion)
        searchSuggestionController.clearSuggestions()
        dismissDiscoverSearchKeyboard()

        if isVenueEventSelection {
            applyDiscoverVenueEventSearchSuggestion(suggestion, resolvedKind: resolvedKind)
            return
        }

        viewModel.searchText = query
        submitDiscoverSearchFromReturn(rememberRecent: false)
    }

    @discardableResult
    private func selectDiscoverPickupSearchSuggestion(_ suggestion: DiscoverSearchSuggestion) -> Bool {
        if let token = suggestion.sportToken,
           token.hasPrefix("pickupGame:"),
           let id = UUID(uuidString: String(token.dropFirst("pickupGame:".count))),
           let row = viewModel.pickupGamesForDiscoverMap.first(where: { $0.id == id }) {
            searchSuggestionController.remember(suggestion)
            searchSuggestionController.clearSuggestions()
            dismissDiscoverSearchKeyboard()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                viewModel.discoverMapContentMode = .pickupGames
                viewModel.discoverPickupSubMode = .games
                viewModel.selectPickupGameOnMap(row)
            }
            pickupGameDetailNav = PickupDetailNavigationToken(id: row.id)
            return true
        }

        if let placeID = suggestion.venueIDs?.first,
           let place = viewModel.pickupPlacesForDiscoverMap.first(where: { $0.id == placeID }) {
            searchSuggestionController.remember(suggestion)
            searchSuggestionController.clearSuggestions()
            dismissDiscoverSearchKeyboard()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                viewModel.discoverMapContentMode = .pickupGames
                viewModel.discoverPickupSubMode = .places
                viewModel.centerMap(on: place, selectForPreview: true)
            }
            return true
        }

        return false
    }

    private func applyDiscoverVenueEventSearchSuggestion(
        _ suggestion: DiscoverSearchSuggestion,
        resolvedKind: DiscoverRecentSearchKind
    ) {
        let languageCode = L10n.normalizedLanguageCode(appLanguageRaw)
        switch resolvedKind {
        case .sport:
            let token = (suggestion.sportToken ?? suggestion.title)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                viewModel.applyDiscoverSportSearchSelection(token, languageCode: languageCode)
            }
        case .league:
            let title = suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let venueIDs = suggestion.venueIDs
                ?? viewModel.discoverVenueEventSearchIndex()
                    .games
                    .filter {
                        DiscoverVenueEventSearch.normalize($0.league ?? "")
                            == DiscoverVenueEventSearch.normalize(suggestion.leagueToken ?? title)
                    }
                    .map(\.venueID)
            viewModel.applyDiscoverVenueEventSearchSelection(
                venueIDs: venueIDs,
                subjectTitle: title,
                languageCode: languageCode
            )
        case .team:
            let title = suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let venueIDs = suggestion.venueIDs
                ?? DiscoverVenueEventSearch.venuesShowingTeam(
                    team: title,
                    index: viewModel.discoverVenueEventSearchIndex()
                ).map(\.venueID)
            viewModel.applyDiscoverVenueEventSearchSelection(
                venueIDs: venueIDs,
                subjectTitle: title,
                languageCode: languageCode
            )
        case .game:
            let title = suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let venueIDs = suggestion.venueIDs
                ?? DiscoverVenueEventSearch.venuesShowingMatchup(
                    title: title,
                    index: viewModel.discoverVenueEventSearchIndex()
                ).map(\.venueID)
            viewModel.applyDiscoverVenueEventSearchSelection(
                venueIDs: venueIDs,
                subjectTitle: title,
                languageCode: languageCode
            )
        case .city, .venue, .pickupPlace, .fan, .proGame:
            viewModel.searchText = suggestion.displayQuery
            submitDiscoverSearchFromReturn(rememberRecent: false)
        }
    }

    private func submitDiscoverSearchFromReturn(rememberRecent: Bool = true) {
        let submittedQuery = viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if rememberRecent {
            searchSuggestionController.rememberSearchText(submittedQuery)
        }
        dismissDiscoverSearchKeyboard()

        if applyTopDiscoverVenueEventSuggestionIfAppropriate(for: submittedQuery) {
            return
        }

        Task { @MainActor in
            let oldRegion = lastMapVenueReloadRegion ?? viewModel.cameraPosition.region
            let addressSearchMovedMap = await viewModel.submitDiscoverAddressSearchFromReturn()
            guard addressSearchMovedMap else { return }
            dismissDiscoverSearchKeyboard()
#if DEBUG
            print("[DiscoverSearchDebug] keyboardDismissedAfterAddressSearch=true")
#endif
            let newRegion = viewModel.cameraPosition.region
            let distanceMovedMiles = oldRegion.flatMap { old in
                newRegion.map { mapVenueReloadDelta(from: old, to: $0).distanceMovedMiles }
            }
            if let newRegion {
                logDiscoverRegionJump(
                    oldRegion: oldRegion,
                    newRegion: newRegion,
                    distanceMovedMiles: distanceMovedMiles,
                    triggeredFastBoundsFetch: true
                )
            }
            await ensureDiscoverDatasetConsistency(
                trigger: "citySearch",
                forceCurrentModeReload: true,
                fastRegionJump: true
            )
            scheduleDiscoverWeatherRefresh(force: true)
#if DEBUG
            print("[DiscoverSearchDebug] mapReloadAfterAddressSearch=true")
#endif
        }
    }

    /// Prefer in-memory venue-event matches over geocoding for matchup/sport/league queries.
    @discardableResult
    private func applyTopDiscoverVenueEventSuggestionIfAppropriate(for query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DiscoverSearchSuggestion.normalizedText(trimmed).count >= 2 else { return false }
        let languageCode = L10n.normalizedLanguageCode(appLanguageRaw)
        let local = viewModel.discoverVenueEventSearchSuggestions(for: trimmed, languageCode: languageCode)
        guard let top = local.first else { return false }

        let normalizedQuery = DiscoverVenueEventSearch.normalize(trimmed)
        let normalizedTitle = DiscoverVenueEventSearch.normalize(top.title)
        let looksLikeMatchup = normalizedQuery.contains(" vs ")
            || normalizedQuery.contains(" v ")
            || normalizedQuery.contains("-")
            || normalizedQuery.split(separator: " ").count == 2
        let isStrong =
            normalizedTitle == normalizedQuery
            || normalizedTitle.hasPrefix(normalizedQuery)
            || (top.kind == .game && looksLikeMatchup)
            || top.kind == .sport
            || top.kind == .league
            || top.kind == .team
        guard isStrong else { return false }

        let mapped = DiscoverSearchSuggestion.fromVenueEventSuggestion(top)
        let kind: DiscoverRecentSearchKind
        switch top.kind {
        case .game: kind = .game
        case .team: kind = .team
        case .sport: kind = .sport
        case .league: kind = .league
        }
        applyDiscoverVenueEventSearchSuggestion(mapped, resolvedKind: kind)
        return true
    }

    private func openDiscoverDatePicker() {
        dismissDiscoverSearchKeyboard()
        viewModel.clampDiscoverMapSelectedDateToMinimumCalendarDayIfNeeded()
        let minDay = viewModel.discoverMapCalendarSelectionMinimumDayStart()
        let cal = Calendar.current
        let rawSelection = cal.startOfDay(for: viewModel.selectedDate)
        let selection = max(rawSelection, minDay)
        discoverDatePickerSelection = selection
        discoverCalendarDisplayedMonth = cal.date(from: cal.dateComponents([.year, .month], from: selection)) ?? selection
        // Freeze the map viewport the user was viewing before overlay layout can disturb the camera.
        viewModel.beginDiscoverDatePickerGeographicFreeze()
        #if DEBUG
        let openedLogFormatter = DateFormatter()
        openedLogFormatter.dateFormat = "yyyy-MM-dd"
        openedLogFormatter.timeZone = TimeZone.current
        print("[DiscoverCalendar] opened at today date=\(openedLogFormatter.string(from: selection))")
        print("===== PICKUP CALENDAR OPEN =====")
        print("selectedDate=\(openedLogFormatter.string(from: selection))")
        print("displayedMonth=\(openedLogFormatter.string(from: discoverCalendarDisplayedMonth))")
        print("sport=\(viewModel.selectedSport)")
        #endif
        // Month availability is independent of selected-day map rows — start the month load
        // immediately (do not wait on day-scoped pickup refresh).
        viewModel.loadDiscoverCalendarDots(
            around: discoverCalendarDisplayedMonth,
            reason: "calendar_open",
            logIfOpeningBeforeReady: true
        )
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            showDatePicker = true
            isCalendarOverlayPresented = true
        }
    }

    private func dismissDiscoverDatePicker() {
        discoverDatePickerSelection = nil
        viewModel.endDiscoverDatePickerGeographicFreeze()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            showDatePicker = false
            isCalendarOverlayPresented = false
        }
    }

    private func applyDiscoverDatePickerSelection() {
        let minDay = viewModel.discoverMapCalendarSelectionMinimumDayStart()
        let raw = discoverDatePickerSelection ?? viewModel.selectedDate
        let appliedDate = max(Calendar.current.startOfDay(for: raw), minDay)
        let isPickup = viewModel.discoverMapContentMode == .pickupGames
        #if DEBUG
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone.current
        let appliedDateString = fmt.string(from: appliedDate)
        print("[CalendarPerf] Done tapped date=\(appliedDateString)")
        if isPickup {
            print("[PickupCalendarPerf] done tapped date=\(appliedDateString)")
        }
        if Calendar.current.startOfDay(for: raw) < minDay {
            print("[DiscoverCalendar] selected date clamped to today")
        }
        #endif

        // Dismiss overlay first so Done stays responsive; defer map/date refresh.
        discoverDatePickerSelection = nil
        viewModel.endDiscoverDatePickerGeographicFreeze()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            showDatePicker = false
            isCalendarOverlayPresented = false
        }
        #if DEBUG
        print("[CalendarPerf] Calendar dismissed date=\(appliedDateString)")
        if isPickup {
            print("[PickupCalendarPerf] dismissed")
        }
        #endif

        let capturedDate = appliedDate
        Task { @MainActor in
            viewModel.noteDiscoverCalendarGuestDatePinnedByUser()
            #if DEBUG
            if isPickup {
                print("[PickupCalendarPerf] background refresh started")
            }
            #endif
            let requestID = viewModel.beginDiscoverDateChange(to: capturedDate)
            viewModel.scheduleDiscoverSelectedDayRefresh(requestID: requestID)
            #if DEBUG
            if isPickup {
                print("[PickupCalendarPerf] background refresh completed")
            }
            #endif
        }
    }
    
    /// Uses existing ``MapViewModel`` loading flags only (no extra fetches).
    private var discoverSummaryDataLoading: Bool {
        switch viewModel.discoverMapContentMode {
        case .pickupGames:
            if isPickupPlacesMode {
                return viewModel.isLoadingPickupPlacesForMap
            }
            return viewModel.isLoadingPickupGamesForMap
        case .venues:
            return viewModel.isLoadingEvents
                || viewModel.isRefreshingDiscoverEvents
                || viewModel.isLoadingMapVenues
                || viewModel.isRefreshingMapVenues
        }
    }

    private var discoverSummaryLoadingFeedbackVisible: Bool {
        discoverSummaryDataLoading
    }

    private var discoverSummaryVenueCount: Int {
        viewModel.mapVisibleBars.count
    }

    private var discoverAllFilterHasNoGamePins: Bool {
        guard viewModel.discoverMapContentMode == .venues,
              viewModel.selectedSport == "All",
              viewModel.mapDisplayMode == .allSpots else { return false }
        return viewModel.mapVisibleBars.contains { !viewModel.venueHasVisibleGameToday($0) }
    }

    private var discoverAllFilterHasNoGamesToday: Bool {
        guard viewModel.discoverMapContentMode == .venues,
              viewModel.selectedSport == "All",
              viewModel.mapDisplayMode == .allSpots else { return false }
        return !viewModel.mapVisibleBars.isEmpty && !viewModel.mapVisibleBars.contains { viewModel.venueHasVisibleGameToday($0) }
    }

    private var discoverNearbySummarySubtitle: String {
        if viewModel.discoverMapContentMode == .pickupGames {
            if isPickupPlacesMode {
                if viewModel.isLoadingPickupPlacesForMap {
                    return "Updating places…"
                }
                let n = viewModel.discoverVisiblePickupPlaceCount
                let q = viewModel.effectiveDiscoverSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                if !q.isEmpty {
                    return n > 0 ? "\(n) pickup places match your search in this area." : "No pickup places match your search in this area."
                }
                return n > 0 ? "Physical places to play in this map area." : "No pickup places in this area."
            }
            if viewModel.isLoadingPickupGamesForMap {
                return "Updating map…"
            }
            let n = discoverPickupPinsInBoundsMatchingSearch
            let q = viewModel.effectiveDiscoverSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if !q.isEmpty {
                return n > 0 ? "\(n) pickup games match your search in this area." : "No pickup games match your search in this area."
            }
            return n > 0 ? "Fan-run games for the selected day in this map area." : "No pickup games in this area for the selected day."
        }
        if discoverSummaryLoadingFeedbackVisible {
            return "Updating venues…"
        }
        if viewModel.selectedSport == "All" {
            switch viewModel.mapDisplayMode {
            case .allSpots:
                return "Showing nearby watch spots"
            case .gamesOnly:
                return discoverSummaryVenueCount > 0 ? "Showing venues with games today" : "No games scheduled today."
            }
        }
        if discoverSummaryVenueCount > 0 {
            return "\(discoverSummaryVenueCount) venues match your selection"
        }
        if viewModel.mapDisplayMode == .gamesOnly {
            return "No games scheduled today."
        }
        return "0 venues match your selection"
    }

    private func pickupPlayersNeededDisplay(_ row: PickupGameRow) -> Int {
        let confirmedPlayers = row.approvedJoinCount
        return max(0, row.playersNeededClamped - confirmedPlayers)
    }

    private func pickupDemandBadgeText(for playersNeeded: Int) -> String {
        switch playersNeeded {
        case 0:
            return "FULL"
        case 1...3:
            return "\(playersNeeded)"
        default:
            return "4+"
        }
    }

    private func logPickupBadgeDebug(row: PickupGameRow, playersNeeded: Int, badgeValue: String) {
#if DEBUG
        print("[PickupBadgeDebug] confirmedPlayers=\(row.approvedJoinCount)")
        print("[PickupBadgeDebug] maxPlayers=\(row.max_players ?? row.playersNeededClamped)")
        print("[PickupBadgeDebug] playersNeeded=\(playersNeeded)")
        print("[PickupBadgeDebug] badgeValue=\(badgeValue)")
#endif
    }

    private func pickupPreviewMetricCapsule(_ text: String, mainInk: Color) -> some View {
        Text(text)
            .font(FGTypography.caption.weight(.semibold))
            .foregroundStyle(mainInk)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.45))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.22 : 0.38), lineWidth: 0.75)
                    }
            }
    }

    private func dominantPickupClusterSport(_ rows: [PickupGameRow]) -> String? {
        var counts: [String: Int] = [:]
        for row in rows {
            let s = row.sport.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { continue }
            counts[s, default: 0] += 1
        }
        return counts.max(by: { $0.value < $1.value })?.key
    }

    private func pickupMarkerActivity(for row: PickupGameRow) -> PickupGameMapMarkerActivity {
        if row.hasPickupGameStarted() || row.approvedJoinCount >= 3 {
            return .high
        }
        if row.approvedJoinCount > 0 || row.pickupOpenSlotsRemaining <= 2 {
            return .medium
        }
        return .low
    }

    private func pickupMarkerActivity(for rows: [PickupGameRow]) -> PickupGameMapMarkerActivity {
        if rows.contains(where: { $0.hasPickupGameStarted() || $0.approvedJoinCount >= 3 }) {
            return .high
        }
        if rows.count >= 3 || rows.contains(where: { $0.approvedJoinCount > 0 || $0.pickupOpenSlotsRemaining <= 2 }) {
            return .medium
        }
        return .low
    }

    private func mapSportIconReusesSportChipIcon(_ sport: String) -> Bool {
        let trimmed = sport.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !SportFilterCatalog.resolve(trimmed).emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func mapSportIconTint(for sport: String) -> Color {
        mapSportIconReusesSportChipIcon(sport) ? SportFilterCatalog.resolve(sport).accent : Color.white.opacity(0.94)
    }

    private func logMapSportIconDebug(sport: String, markerType: String) {
#if DEBUG
        print("[MapSportIconDebug] reusedSportChipIcon=\(mapSportIconReusesSportChipIcon(sport))")
        print("[MapSportIconDebug] sport=\(sport)")
        print("[MapSportIconDebug] markerType=\(markerType)")
#endif
    }

    private func pickupGameMapPinButton(row: PickupGameRow) -> some View {
        let display = pickupMapMarkerDisplayValues(for: row)
        logPickupBadgeDebug(row: row, playersNeeded: display.needed, badgeValue: display.badgeValue ?? "none")
        return Button {
            FGInteractionHaptics.selection()
            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                viewModel.selectPickupGameOnMap(row)
            }
        } label: {
            PickupGameMapMarker(
                sport: row.sport,
                accentColor: display.accentColor,
                markerType: "pickup",
                reusedSportChipIcon: display.reusedSportChipIcon,
                activity: display.activity,
                demandBadgeText: display.badgeValue,
                isSelected: display.isSelected,
                allowsPulse: display.allowsPulse
            )
            .zIndex(display.isSelected ? 30 : 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pickup \(AppSportCatalog.displayLabel(forSportToken: row.sport)), \(display.needed) spots open, \(row.title)")
    }

    private func pickupPlacePrimarySport(_ place: PickupPlaceRow) -> String {
        let firstTag = place.sportTags.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !firstTag.isEmpty { return firstTag }
        return "Pickup"
    }

    private func pickupPlaceSportSymbol(for place: PickupPlaceRow) -> String {
        let text = ([pickupPlacePrimarySport(place), place.placeType ?? ""] + place.sportTags)
            .joined(separator: " ")
            .lowercased()
        if text.contains("soccer") { return "soccerball" }
        if text.contains("basketball") { return "basketball.fill" }
        if text.contains("baseball") || text.contains("softball") { return "baseball.fill" }
        if text.contains("tennis") || text.contains("pickleball") || text.contains("badminton") || text.contains("padel") { return "figure.tennis" }
        if text.contains("paragliding") || text.contains("hang_gliding") || text.contains("hang gliding") || text.contains("paramotoring") { return "wind" }
        if text.contains("volleyball") { return "volleyball.fill" }
        if text.contains("dance") || text.contains("breakdance") || text.contains("breaking") || text.contains("ballet") { return "figure.dance" }
        return "sportscourt.fill"
    }

    private func pickupPlaceMapPinButton(place: PickupPlaceRow) -> some View {
        let isSelected = viewModel.selectedPickupPlaceForMap?.id == place.id
        let symbolName = pickupPlaceSportSymbol(for: place)
        let sportLabel = pickupPlacePrimarySport(place)
#if DEBUG
        let _: Void = DebugLogGate.noisy("[PickupPlacesDebug] markerRendered=true id=\(place.id.uuidString.lowercased())")
#endif

        return Button {
            FGInteractionHaptics.selection()
            withAnimation(.spring()) {
                viewModel.centerMap(on: place)
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.gray.opacity(colorScheme == .dark ? 0.22 : 0.16))
                    .frame(width: isSelected ? 46 : 40, height: isSelected ? 46 : 40)
                    .blur(radius: isSelected && isDiscoverTabSelected ? 3 : 0)

                Circle()
                    .fill(colorScheme == .dark ? Color.black.opacity(0.82) : Color.white.opacity(0.92))
                    .frame(width: isSelected ? 36 : 32, height: isSelected ? 36 : 32)
                    .overlay {
                        Circle()
                            .strokeBorder(Color.gray.opacity(isSelected ? 0.86 : 0.48), lineWidth: isSelected ? 2 : 1)
                    }
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.12), radius: 5, y: 2)

                Image(systemName: symbolName)
                    .font(.system(size: isSelected ? 16 : 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.82) : Color.gray.opacity(0.86))
            }
            .animation(isDiscoverTabSelected ? .spring(response: 0.28, dampingFraction: 0.78) : nil, value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(sportLabel) pickup place, \(place.name)")
    }

    @ViewBuilder
    private func multiPickupPlaceClusterAnnotation(cluster: PickupPlaceCluster) -> some View {
        Button {
            FGInteractionHaptics.selection()
            openPickupPlaceClusterSheet(cluster)
        } label: {
            ZStack {
                Circle()
                    .fill(Color.gray.opacity(colorScheme == .dark ? 0.24 : 0.16))
                    .frame(width: 48, height: 48)
                    .blur(radius: 0)
                Circle()
                    .fill(colorScheme == .dark ? Color.black.opacity(0.82) : Color.white.opacity(0.92))
                    .frame(width: 36, height: 36)
                    .overlay {
                        Circle()
                            .strokeBorder(Color.gray.opacity(0.56), lineWidth: 1.25)
                    }
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.12), radius: 5, y: 2)
                Text("\(cluster.count)")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.82) : Color.gray.opacity(0.9))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(cluster.count) pickup places")
    }

    @ViewBuilder
    private func multiPickupGameClusterAnnotation(cluster: PickupGameCluster) -> some View {
        let sportHint = dominantPickupClusterSport(cluster.rows)
        let activity = pickupMarkerActivity(for: cluster.rows)
        Button {
            FGInteractionHaptics.selection()
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                viewModel.zoomTowardCluster(center: cluster.coordinate)
            }
        } label: {
            PickupGameMapMarker(
                sport: sportHint ?? "",
                accentColor: viewModel.colorForSport(sportHint ?? ""),
                markerType: "pickupCluster",
                reusedSportChipIcon: mapSportIconReusesSportChipIcon(sportHint ?? ""),
                activity: activity,
                isCluster: true,
                allowsPulse: pickupMarkerAllowsPulse(isSelected: false, activity: activity),
                count: cluster.count
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(cluster.count) pickup games")
    }

    private func discoverPickupPlacePreviewCard(_ place: PickupPlaceRow) -> some View {
        let mainInk = colorScheme == .dark ? Color.white.opacity(0.92) : FGColor.primaryText(colorScheme)
        let subInk = colorScheme == .dark ? Color.white.opacity(0.70) : FGColor.secondaryText(colorScheme)
        let placeType = place.typeDisplay
        let sport = pickupPlacePrimarySport(place)
        let cityState = place.cityStateDisplay
        let symbolName = pickupPlaceSportSymbol(for: place)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.gray.opacity(0.12))
                        .frame(width: 46, height: 46)
                    Image(systemName: symbolName)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.82) : Color.gray.opacity(0.82))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Pickup place")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(subInk)
                        .tracking(0.4)
                    Text(place.name)
                        .font(FGTypography.sectionTitle)
                        .foregroundStyle(mainInk)
                        .lineLimit(2)
                    Text("\(AppSportCatalog.displayLabel(forSportToken: sport)) • \(placeType)")
                        .font(FGTypography.metadata.weight(.medium))
                        .foregroundStyle(subInk)
                        .lineLimit(2)
                    if !cityState.isEmpty {
                        Label(cityState, systemImage: "mappin.circle.fill")
                            .font(FGTypography.caption.weight(.medium))
                            .foregroundStyle(subInk)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                        viewModel.clearPickupMapSelection()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.65) : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss pickup place")
            }

            HStack(spacing: 10) {
                Button {
                    viewModel.openDirections(to: place)
                } label: {
                    Label("Directions", systemImage: "location.fill")
                        .font(FGTypography.cardTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.gray)

                Button {
                    openPickupHostFlow(from: place)
                } label: {
                    Text("Create Pickup Game Here")
                        .font(FGTypography.cardTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.42), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.14), radius: 18, y: 10)
    }

    private func openPickupHostFlow(from place: PickupPlaceRow) {
#if DEBUG
        print("[PickupHostPrefillDebug] selectedPlace=\(place.id.uuidString.lowercased()) name=\(place.name) sport=\(place.primarySport) city=\(place.city ?? "nil") state=\(place.state ?? "nil") latitude=\(place.latitude) longitude=\(place.longitude)")
#endif
        guard viewModel.isAuthenticatedForSocialFeatures else {
            viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
            return
        }
        guard viewModel.canFanUsePickupGamesUI else {
            viewModel.logBusinessUserGateBlocked(action: "createPickupGameFromPickupPlace")
            viewModel.showSocialActionToast(BusinessFanGateCopy.pickupFanOnly, isError: true)
            return
        }
#if DEBUG
        print("[PickupHostPrefillDebug] openingHostFlow=true placeId=\(place.id.uuidString.lowercased())")
#endif
        pickupHostPrefillPlace = place
    }

    private func openPickupPlaceClusterSheet(_ cluster: PickupPlaceCluster) {
#if DEBUG
        print("[PickupPlaceClusterDebug] tappedClusterCount=\(cluster.count)")
        print("[PickupPlaceClusterDebug] openedSheet=true")
#endif
        viewModel.selectedPickupPlaceForMap = nil
        pickupPlaceClusterForSheet = cluster
    }

    private func hostPickupGameFromPickupPlaceClusterSheet(_ place: PickupPlaceRow) {
#if DEBUG
        print("[PickupPlaceClusterDebug] selectedPlaceId=\(place.id.uuidString.lowercased())")
        print("[PickupPlaceClusterDebug] hostGameHereTapped=true")
#endif
        pendingPickupPlaceHostFromClusterDismiss = place
        pickupPlaceClusterForSheet = nil
    }

    private func openPendingPickupPlaceHostFromClusterIfNeeded() {
        guard let place = pendingPickupPlaceHostFromClusterDismiss else { return }
        pendingPickupPlaceHostFromClusterDismiss = nil
        openPickupHostFlow(from: place)
    }

    private func discoverPickupPreviewCard(
        _ row: PickupGameRow,
        guestMapsActionsToLogin: Bool,
        onOpenDetails: @escaping () -> Void
    ) -> some View {
        let locationLine: String = {
            guard !guestMapsActionsToLogin else { return "" }
            return [row.address, row.city, row.state]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        }()
        let detailSubtitle: String = {
            if guestMapsActionsToLogin {
                return "Sign in to see schedule, location, and roster details"
            }
            return "\(AppSportCatalog.displayLabel(forSportToken: row.sport)) • \(row.skillLevelEnum.displayTitle) • \(row.playEnvironmentEnum.shortLabel)"
        }()
        let sportTint = viewModel.colorForSport(row.sport)
        let sportEmoji = viewModel.emojiForSport(row.sport)
        let sportIconName = viewModel.iconForSport(row.sport)
        let mainInk = colorScheme == .dark ? Color.white.opacity(0.92) : FGColor.primaryText(colorScheme)
        let subInk = colorScheme == .dark ? Color.white.opacity(0.72) : FGColor.secondaryText(colorScheme)
        let dismissIcon = colorScheme == .dark ? Color.white.opacity(0.72) : Color.secondary
        let previewCorner: CGFloat = 30

        let detailTitle = guestMapsActionsToLogin ? "Log in / Sign up" : "Details & join"
        let openDetailAction = {
            if guestMapsActionsToLogin {
                presentGuestPickupPreviewAuth()
            } else {
                onOpenDetails()
            }
        }
        let showStarted = !guestMapsActionsToLogin && row.hasPickupGameStarted()

        return VStack(alignment: .leading, spacing: FGSpacing.md) {
            HStack(alignment: .top, spacing: FGSpacing.md) {
                PickupGameStartedSportGlyphFrame(showStarted: showStarted) {
                    ZStack {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 58, height: 58)
                            .overlay {
                                Circle()
                                    .strokeBorder(
                                        LinearGradient(
                                            colors: [
                                                Color.white.opacity(colorScheme == .dark ? 0.35 : 0.65),
                                                sportTint.opacity(0.55)
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 1.25
                                    )
                            }
                            .shadow(color: sportTint.opacity(0.35), radius: 10, y: 4)

                        if !sportEmoji.isEmpty {
                            Text(sportEmoji)
                                .font(.system(size: 30))
                                .accessibilityHidden(true)
                        } else {
                            Image(systemName: sportIconName)
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(sportTint)
                                .accessibilityHidden(true)
                        }
                    }
                }

                Button {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
                        openDetailAction()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        GameFormatBadgeView(format: row.gameFormat, colorScheme: colorScheme)
                        Text(guestMapsActionsToLogin ? AppSportCatalog.displayLabel(forSportToken: row.sport) : row.title)
                            .font(FGTypography.sectionTitle)
                            .foregroundStyle(mainInk)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(detailSubtitle)
                            .font(FGTypography.metadata.weight(.medium))
                            .foregroundStyle(subInk)
                            .lineLimit(2)
                            .minimumScaleFactor(0.88)

                        if !guestMapsActionsToLogin, let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "clock.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(subInk)
                                Text(
                                    row.pickupDateWithCompactTimeRange(languageCode: appLanguageRaw)
                                        ?? start.formatted(
                                            Date.FormatStyle.dateTime
                                                .month(.abbreviated)
                                                .day()
                                                .year()
                                                .hour()
                                                .minute()
                                                .locale(
                                                    Locale(
                                                        identifier: L10n.normalizedLanguageCode(appLanguageRaw)
                                                            .replacingOccurrences(of: "-", with: "_")
                                                    )
                                                )
                                        )
                                )
                                    .font(FGTypography.metadata.weight(.semibold))
                                    .foregroundStyle(mainInk)
                            }
                            if showStarted {
                                PickupGameStartedLineCaption()
                                    .padding(.top, 2)
                            }
                        }

                        if !guestMapsActionsToLogin {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "person.2.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(FGColor.accentGreen)
                                Text(row.participantAudienceDisplayTitle)
                                    .font(FGTypography.caption.weight(.medium))
                                    .foregroundStyle(subInk)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if !locationLine.isEmpty {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(FGColor.accentBlue)
                                Text(locationLine)
                                    .font(FGTypography.caption)
                                    .foregroundStyle(subInk)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if !guestMapsActionsToLogin {
                            HStack(spacing: FGSpacing.sm) {
                                let playersNeeded = pickupPlayersNeededDisplay(row)
                                pickupPreviewMetricCapsule(
                                    pickupLocalizedSpotsLeft(
                                        playersNeeded,
                                        languageCode: appLanguageRaw
                                    ),
                                    mainInk: mainInk
                                )
                                pickupPreviewMetricCapsule(row.pickupCompactDurationLabel ?? "\(playersNeeded) players needed", mainInk: mainInk)
                            }
                            .padding(.top, 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                        viewModel.clearPickupMapSelection()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(dismissIcon)
                }
                .buttonStyle(.plain)
            }

            if !guestMapsActionsToLogin {
                PickupOrganizerPreviewIdentityRow(
                    viewModel: viewModel,
                    organizerUserId: row.creator_user_id,
                    colorScheme: colorScheme
                )
            }

            HStack(spacing: FGSpacing.sm) {
                if !guestMapsActionsToLogin, let lat = row.latitude, let lon = row.longitude {
                    Button {
                        if let url = URL(string: "http://maps.apple.com/?ll=\(lat),\(lon)&q=Pickup%20game") {
                            openURL(url)
                        }
                    } label: {
                        Label("Directions", systemImage: "map")
                            .font(FGTypography.metadata.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(FGColor.accentBlue)
                }

                if viewModel.discoverMapContentMode == .pickupGames {
                    Button {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
                            openDetailAction()
                        }
                    } label: {
                        Text(detailTitle)
                            .font(FGTypography.metadata.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.78)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(colorScheme == .dark ? Color.white.opacity(0.92) : FGColor.accentBlue)
                }
            }
        }
        .padding(FGSpacing.lg)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: previewCorner, style: .continuous)
                    .fill(.ultraThinMaterial)
                LinearGradient(
                    colors: [
                        Color.black.opacity(colorScheme == .dark ? 0.62 : 0.2),
                        Color.black.opacity(colorScheme == .dark ? 0.4 : 0.11)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .clipShape(RoundedRectangle(cornerRadius: previewCorner, style: .continuous))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: previewCorner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: previewCorner, style: .continuous)
                .strokeBorder(discoverPreviewCardBorder, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.42 : 0.16), radius: colorScheme == .dark ? 28 : 18, x: 0, y: colorScheme == .dark ? 16 : 10)
        .shadow(color: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.1 : 0.05), radius: 14, x: 0, y: 3)
        .task(id: row.id) {
            guard !guestMapsActionsToLogin else { return }
            PickupOrganizerTrustDebug.lifecycle("selected pickup card opened")
            await viewModel.loadPickupCreatorProfilesIfNeeded(creatorUserIds: [row.creator_user_id])
            if viewModel.pickupOrganizerSummary(for: row.creator_user_id) != nil {
                PickupOrganizerTrustDebug.lifecycle("organizer statistics served from cache")
            } else {
                PickupOrganizerTrustDebug.lifecycle("organizer statistics found in existing payload", details: "none")
            }
            await viewModel.refreshPickupOrganizerSummaries(userIds: [row.creator_user_id])
        }
        .onAppear {
            guard !guestMapsActionsToLogin else { return }
            PickupGameStartedStateDebug.log(
                row: row,
                now: Date(),
                allowedActions: "discover_map_preview"
            )
        }
    }

    private func presentGuestPickupPreviewAuth() {
#if DEBUG
        print("[GuestPickupAuthDebug] loginSignupTapped source=pickupPreview")
        print("[GuestPickupAuthDebug] presentAuth source=pickupPreview")
#endif
        viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
    }

    private var discoverPickupPinsInBounds: Int {
        viewModel.pickupGamesVisibleAsMapPins(for: viewModel.currentMapRegionBounds()).count
    }

    private var discoverPickupPinsInBoundsMatchingSearch: Int {
        viewModel.pickupGamesVisibleAsMapPinsWithDiscoverSearch(for: viewModel.currentMapRegionBounds()).count
    }

    private func discoverWatchPlayIntentToggle(layoutWidth: CGFloat) -> some View {
        let languageCode = L10n.normalizedLanguageCode(appLanguageRaw)
        let tileSide = discoverWatchPlayTileSide(for: layoutWidth)

        return HStack(spacing: 5) {
            discoverWatchPlayIntentTile(
                mode: .venues,
                title: L10n.t("discover_intent_watch", languageCode: languageCode),
                systemImage: "sportscourt.fill",
                selectedTint: FGColor.intentWatch,
                tileSide: tileSide,
                accessibilityHint: L10n.t("discover_intent_watch_a11y_hint", languageCode: languageCode)
            )
            discoverWatchPlayIntentTile(
                mode: .pickupGames,
                title: L10n.t("discover_intent_play", languageCode: languageCode),
                systemImage: "figure.run",
                selectedTint: FGColor.intentPlay,
                tileSide: tileSide,
                accessibilityHint: L10n.t("discover_intent_play_a11y_hint", languageCode: languageCode)
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("discover_dock_intent_a11y_group", languageCode: languageCode))
        .animation(discoverBottomControlModeSpring, value: viewModel.discoverMapContentMode)
    }

    private func discoverWatchPlayIntentTile(
        mode: DiscoverMapContentMode,
        title: String,
        systemImage: String,
        selectedTint: Color,
        tileSide: CGFloat,
        accessibilityHint: String
    ) -> some View {
        let selected = viewModel.discoverMapContentMode == mode
        return Button {
            guard viewModel.discoverMapContentMode != mode else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            discoverLogBottomControlModeSwitch(to: mode)
            withAnimation(discoverBottomControlModeSpring) {
                viewModel.clearDiscoverMapContentSelectionsWhenSwitching(to: mode)
                // Preserve in-session Play submode (Places default; Games if user already chose it).
                // Do not force `.games` on every Play entry.
                viewModel.discoverMapContentMode = mode
            }
        } label: {
            ZStack {
                // Selection chrome only when selected — never attach matchedGeometryEffect to
                // unselected tiles (same ID on both caused Play label to disappear).
                if selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(selectedTint)
                        .matchedGeometryEffect(id: "discoverModeSelection", in: discoverModeToggleNamespace)
                        .shadow(
                            color: selectedTint.opacity(colorScheme == .dark ? 0.30 : 0.18),
                            radius: 3,
                            y: 1
                        )
                }

                VStack(spacing: 3) {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .semibold))
                    Text(title)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .foregroundStyle(selected ? Color.white : FGColor.secondaryText(colorScheme))
            }
            .frame(width: tileSide, height: tileSide)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(DiscoverModeSegmentButtonStyle())
        .accessibilityLabel(title)
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func discoverBottomModeSelectionCapsule(tint: Color) -> some View {
        Capsule(style: .continuous)
            .fill(tint)
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.22 : 0.14), lineWidth: 0.6)
            }
            .shadow(color: tint.opacity(colorScheme == .dark ? 0.22 : 0.14), radius: 2, y: 1)
    }

    private func discoverBottomModeSegmentText(
        _ title: String,
        selected: Bool,
        allowsMultiline: Bool = false
    ) -> some View {
        Group {
            if allowsMultiline {
                // Prefer Hosting / Games on two lines when width is compact.
                let lines = title.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                if lines.count == 2 {
                    VStack(spacing: 0) {
                        Text(String(lines[0]))
                        Text(String(lines[1]))
                    }
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                } else {
                    Text(title)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.85)
                }
            } else {
                Text(title)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        }
        .foregroundStyle(selected ? Color.white : FGColor.secondaryText(colorScheme))
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Capsule(style: .continuous))
    }

    private func discoverBottomAdStrip(layoutWidth: CGFloat) -> some View {
        let availableWidth = discoverAdBannerAvailableWidth(for: layoutWidth)
        let bannerSize = discoverAdaptiveBannerSize(for: layoutWidth)
        let adUnitID = AdMobConfiguration.bannerAdUnitID(for: "discover.bottomStrip")
        let visibleHeight = discoverBottomAdLoaded ? bannerSize.height : 0
        let _ = discoverLogAdBannerDebug(
            adUnitID: adUnitID,
            availableWidth: availableWidth,
            bannerSize: bannerSize,
            containerSize: bannerSize
        )

        return ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(colorScheme == .dark ? .thinMaterial : .ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(colorScheme == .dark ? Color.black.opacity(0.24) : Color.white.opacity(0.14))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.08 : 0.16),
                                    Color.white.opacity(0.02)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

            AdaptiveBannerView(
                placement: "discover.bottomStrip",
                adUnitID: adUnitID,
                layoutWidth: availableWidth,
                requestBackoffUntil: discoverBottomAdBackoffUntil,
                onAdLoaded: {
                    AdDebugDiagnostics.logDiscoverMapBanner(
                        phase: "stripCallback",
                        adLoadSucceeded: true
                    )
                    discoverBottomAdRetryTask?.cancel()
                    discoverBottomAdRetryTask = nil
                    discoverBottomAdNoFillRetryCount = 0
                    discoverBottomAdBackoffUntil = nil
                    discoverTopAdLoadFailed = false
                    discoverBottomAdLoaded = true
                },
                onAdFailed: { error in
                    AdDebugDiagnostics.logDiscoverMapBanner(
                        phase: "stripCallback",
                        adLoadFailed: true,
                        extra: ["error": error.localizedDescription]
                    )
                    let failureReason = AdDebugDiagnostics.loadFailedReason(for: error)
                    AdDebugDiagnostics.logCollapsedAdSpace(
                        format: "banner",
                        placement: "discover.bottomStrip",
                        unitID: adUnitID,
                        error: error
                    )
                    discoverTopAdLoadFailed = true
                    discoverBottomAdLoaded = false
                    scheduleDiscoverBottomAdRetry(failureReason: failureReason, unitID: adUnitID)
                }
            )
            .id(discoverBottomAdRetryToken)
            .frame(width: bannerSize.width, height: bannerSize.height)
            .opacity(1)
            .allowsHitTesting(discoverBottomAdLoaded)
            .accessibilityElement(children: .contain)
        }
        .frame(width: bannerSize.width, height: visibleHeight, alignment: .center)
        .fixedSize(horizontal: true, vertical: true)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.07), lineWidth: 0.75)
        }
        .shadow(color: Color.black.opacity(discoverBottomAdLoaded ? (colorScheme == .dark ? 0.18 : 0.07) : 0), radius: 10, y: 4)
        .opacity(discoverBottomAdLoaded ? 0.94 : 0)
        .accessibilityHidden(!discoverBottomAdLoaded)
        .zIndex(8)
        .frame(maxWidth: .infinity, alignment: .center)
        .allowsHitTesting(discoverBottomAdLoaded)
        .onAppear {
            AdDebugDiagnostics.logDiscoverMapBanner(phase: "stripAppear")
        }
    }

    private func scheduleDiscoverBottomAdRetry(
        failureReason: AdDebugDiagnostics.AdLoadFailedReason,
        unitID: String
    ) {
        discoverBottomAdRetryTask?.cancel()
        let delaySeconds: TimeInterval
        if failureReason == .noFill {
            discoverBottomAdNoFillRetryCount += 1
            switch discoverBottomAdNoFillRetryCount {
            case 1:
                delaySeconds = 30
            case 2:
                delaySeconds = 60
            default:
                delaySeconds = 120
            }
        } else {
            delaySeconds = 30
        }
        discoverBottomAdBackoffUntil = Date().addingTimeInterval(delaySeconds)
        AdDebugDiagnostics.logRetryScheduled(
            format: "banner",
            placement: "discover.bottomStrip",
            unitID: unitID,
            delaySeconds: delaySeconds,
            retryBackoffCount: discoverBottomAdNoFillRetryCount,
            failureReason: failureReason
        )
        discoverBottomAdRetryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            discoverBottomAdBackoffUntil = nil
            discoverTopAdLoadFailed = false
            discoverBottomAdRetryToken += 1
        }
    }

    private func discoverLogAdBannerDebug(adUnitID: String, availableWidth: CGFloat, bannerSize: CGSize, containerSize: CGSize) {
        let dedupeKey = [
            adUnitID,
            String(format: "%.0f", Double(availableWidth)),
            String(format: "%.0f", Double(bannerSize.width)),
            String(format: "%.0f", Double(bannerSize.height))
        ].joined(separator: "|")
        AdDebugDiagnostics.logEventOnce(
            event: "discoverStripLayout",
            format: "banner",
            placement: "discover.bottomStrip",
            dedupeKey: dedupeKey,
            fields: [
                "availableWidth": String(format: "%.1f", Double(availableWidth)),
                "adaptiveBannerW": String(format: "%.1f", Double(bannerSize.width)),
                "adaptiveBannerH": String(format: "%.1f", Double(bannerSize.height)),
                "containerW": String(format: "%.1f", Double(containerSize.width)),
                "containerH": String(format: "%.1f", Double(containerSize.height)),
                "zeroAvailableWidth": "\(availableWidth <= 0)",
                "iPad": "\(UIDevice.current.userInterfaceIdiom == .pad)"
            ]
        )
    }

    private func discoverMapStatusBanner(text: String, isLoading: Bool, isError: Bool = false) -> some View {
        HStack(spacing: FGSpacing.sm) {
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                } else if isError {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(FGColor.accentYellow)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(FGColor.accentGreen)
                        .accessibilityHidden(true)
                }
            }
            Text(text)
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(2)
                .minimumScaleFactor(0.88)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, FGSpacing.sm)
        .background(.ultraThinMaterial)
        .clipShape(Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.16 : 0.06), radius: 10, y: 4)
    }

    private func discoverMapToastBanner(text: String, isError: Bool) -> some View {
        HStack(spacing: FGSpacing.sm) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? FGColor.accentYellow : FGColor.accentGreen)
            Text(text)
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(2)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, FGSpacing.sm)
        .background(.ultraThinMaterial)
        .clipShape(Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.16 : 0.06), radius: 10, y: 4)
    }

    /// City / region line for logged-out teaser (no street-level detail).
    private func teaserAreaDescription(for bar: BarVenue) -> String {
        let parts = bar.address.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "Location on map" }
        if parts.count == 1, let onlyPart = parts.first { return String(onlyPart) }
        return parts.suffix(2).joined(separator: ", ")
    }

    private func loggedOutVenueTeaserCard(_ bar: BarVenue) -> some View {
        GuestDiscoverLockedPreviewCard(
            accent: FGColor.accentBlue,
            headline: "Preview only",
            teaser: {
                VStack(alignment: .leading, spacing: FGSpacing.xs) {
                    Text(bar.name)
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text("Watch spot")
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                    Text(teaserAreaDescription(for: bar))
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
            },
            onLogIn: {
                pendingResumeVenueIDAfterLogin = bar.id
                viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
            },
            onCreateAccount: {
                pendingResumeVenueIDAfterLogin = bar.id
                viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: true)
            },
            onDismiss: {
                withAnimation(.spring()) {
                    venuePreviewDetailEvent = nil
                    showVenueDetails = false
                    showVenueRatingSheet = false
                    viewModel.selectedBar = nil
                    viewModel.clearDiscoverRemotePreviewHold()
                    pendingResumeVenueIDAfterLogin = nil
                }
            },
            onNotNow: {
                withAnimation(.spring()) {
                    venuePreviewDetailEvent = nil
                    showVenueDetails = false
                    showVenueRatingSheet = false
                    viewModel.selectedBar = nil
                    viewModel.clearDiscoverRemotePreviewHold()
                    pendingResumeVenueIDAfterLogin = nil
                }
            }
        )
    }

    private var discoverPreviewCardMaterial: Material {
        colorScheme == .dark ? .regularMaterial : .ultraThinMaterial
    }

    private var discoverPreviewCardTint: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.78)
            : Color.white.opacity(0.78)
    }

    private var discoverPreviewCardBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.15)
            : FGColor.divider(colorScheme)
    }

    private var discoverPreviewSecondaryTextColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.82)
            : FGColor.secondaryText(colorScheme)
    }

    private var discoverPreviewMutedIconColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.74)
            : .secondary
    }

    private var discoverPreviewControlBackground: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.56)
            : FGColor.cardBackground(colorScheme)
    }

    private var discoverPreviewControlBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.14)
            : FGColor.divider(colorScheme)
    }

    private var discoverPreviewInnerSurface: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.54)
            : FGColor.background(colorScheme).opacity(0.90)
    }

    private var venueGameElevatedSurface: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.055)
            : Color.white.opacity(0.97)
    }

    private var venueGamePredictionInsetSurface: Color {
        colorScheme == .dark
            ? FGColor.accentBlue.opacity(0.12)
            : FGColor.accentBlue.opacity(0.055)
    }

    private var discoverPreviewAccentSurface: Color {
        colorScheme == .dark
            ? FGColor.accentGreen.opacity(0.18)
            : FGColor.accentGreen.opacity(0.09)
    }
    
    /// Venue image, name, address, actions, rating, and experience — scrolls with game content.
    @ViewBuilder
    private func venuePreviewCardStaticHeader(bar: BarVenue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                venueHeroImage(bar)

                HStack(spacing: 8) {
                    discoverHomeCrowdHeroButton(bar: bar)

                    Button {
                        FGInteractionHaptics.softImpact()
                        if viewModel.canFavoriteVenues {
                            viewModel.toggleFavorite(bar)
                        } else if viewModel.isAuthenticatedForSocialFeatures {
                            viewModel.logBusinessUserGateBlocked(action: "favoriteVenue")
                            fanFeatureGateAlertMessage = BusinessFanGateCopy.actionTapBlocked
                        } else {
                            viewModel.discoverNavigateToAccountForUserAuth = true
                        }
                    } label: {
                        Image(systemName: viewModel.canFavoriteVenues && viewModel.favoriteVenueIDs.contains(bar.id) ? "heart.fill" : "heart")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(viewModel.canFavoriteVenues && viewModel.favoriteVenueIDs.contains(bar.id) ? .red : FGColor.primaryText(colorScheme))
                            .softActiveGlow(viewModel.canFavoriteVenues && viewModel.favoriteVenueIDs.contains(bar.id), color: .red)
                            .frame(width: 34, height: 34)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    .buttonStyle(FGPremiumPressButtonStyle(hapticOnPress: false))

                    Button {
                        FGInteractionHaptics.selection()
                        closeVenuePreview()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(FGColor.dangerRed)
                            .frame(width: 34, height: 34)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    .buttonStyle(FGPremiumPressButtonStyle(hapticOnPress: false))
                }
                .padding(10)
            }
            .onAppear {
                let selected = viewModel.isHomeCrowdVenue(bar.id)
                print(
                    "[HomeCrowd] discoverHeroIconRendered venueId=\(bar.id.uuidString.lowercased()) selected=\(selected)"
                )
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: FGSpacing.sm) {
                    Text(bar.name)
                        .font(FGTypography.sectionTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                        .layoutPriority(1)

                    venuePreviewRatingButton(bar)
                }
            }
        }
        .onAppear {
#if DEBUG
            print("[VenuePreviewHeaderDebug] addressRemoved=true")
            print("[VenueFeatureDebug] propagatedToDiscover=true")
            print("[VenueFeatureDebug] discoverCardFeatureChipsRemoved=true")
            print("[VenueFeatureDebug] sourceOfTruth=venues.features,venues.screen_count,venues.serves_food,venues.has_wifi,venues.has_garden,venues.has_projector,venues.pet_friendly")
            if bar.hasBusinessVerifiedFeatures {
                print("[VenueFeatureDebug] approvedBusinessVenueFeaturesVerified=true")
            }
#endif
        }
    }

    private func closeVenuePreview() {
        withAnimation(.spring()) {
            venuePreviewDetailEvent = nil
            showVenueDetails = false
            showVenueRatingSheet = false
            viewModel.selectedBar = nil
            viewModel.clearDiscoverRemotePreviewHold()
            pendingResumeVenueIDAfterLogin = nil
        }
    }

    private func discoverHomeCrowdHeroButton(bar: BarVenue) -> some View {
        let isActive = viewModel.isHomeCrowdVenue(bar.id)

        return Button {
            FGInteractionHaptics.softImpact()
            let willSelect = !isActive
            print(
                "[HomeCrowd] toggleTap source=discoverHero venueId=\(bar.id.uuidString.lowercased()) selected=\(willSelect)"
            )
            if viewModel.canUseFanSocialFeatures {
                Task {
                    isDiscoverHomeCrowdToggleInFlight = true
                    defer { isDiscoverHomeCrowdToggleInFlight = false }
                    await viewModel.toggleHomeCrowd(for: bar)
                }
            } else if viewModel.isAuthenticatedForSocialFeatures {
                viewModel.logBusinessUserGateBlocked(action: "toggleHomeCrowd")
                fanFeatureGateAlertMessage = BusinessFanGateCopy.actionTapBlocked
            } else {
                viewModel.discoverNavigateToAccountForUserAuth = true
            }
        } label: {
            HomeCrowdShieldStarBadge(
                diameter: 34,
                visualState: isActive ? .active : .inactive
            )
            .background {
                if !isActive {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 34, height: 34)
                }
            }
            .overlay {
                Circle()
                    .strokeBorder(
                        isActive
                            ? Color(red: 0.72, green: 0.48, blue: 1.0).opacity(0.88)
                            : discoverPreviewControlBorder,
                        lineWidth: isActive ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(FGPremiumPressButtonStyle(hapticOnPress: false))
        .disabled(isDiscoverHomeCrowdToggleInFlight)
        .accessibilityLabel(isActive ? "Remove this Home Venue" : "Make this my Home Venue")
    }

    private func venuePreviewRatingButton(_ bar: BarVenue) -> some View {
        Button {
            if viewModel.canRateVenues {
                showVenueRatingSheet = true
            } else if viewModel.isGuestDiscoverMode {
                viewModel.discoverNavigateToAccountForUserAuth = true
            } else if viewModel.isAuthenticatedForSocialFeatures {
                viewModel.logBusinessUserGateBlocked(action: "rateVenue")
                fanFeatureGateAlertMessage = BusinessFanGateCopy.actionTapBlocked
            }
        } label: {
            let rating = viewModel.mergedDisplayRating(for: bar)
            let reviewCount = viewModel.reviewCountDisplay(for: bar)
            HStack(spacing: 5) {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                if let rating, reviewCount > 0 {
                    Text(String(format: "%.1f", rating))
                        .fontWeight(.bold)
                } else {
                    Text("Rate")
                        .fontWeight(.semibold)
                }
            }
            .font(FGTypography.metadata)
            .padding(.horizontal, FGSpacing.sm)
            .padding(.vertical, FGSpacing.xs)
            .background(discoverPreviewControlBackground)
            .clipShape(Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(discoverPreviewControlBorder, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func venuePreviewCard(_ bar: BarVenue) -> some View {
        let resolved = viewModel.canonicalBarForDiscover(bar)
        let gamesToday = viewModel.gamesForVenuePreview(
            bar: resolved,
            date: viewModel.selectedDate,
            sportFilter: viewModel.selectedSport
        )
#if DEBUG
        let _: Void = {
            print("[VenuePreviewDebug] present source=single count=1")
            print("[VenuePreviewDebug] selected venueId=\(resolved.id.uuidString.lowercased())")
            print("[VenuePreviewDebug] render count=1 uniqueIds=1")
            print("[VenuePreviewDebug] invalidDuplicateIds=0")
        }()
#endif

        // Concrete leaf host keeps DiscoverScreen’s opaque preview type shallow so SwiftUI
        // metadata instantiation cannot recursively explode through bottom-overlay generics.
        return DiscoverMapVenuePreviewCardHost(
            venueId: resolved.id,
            chromeMaterial: discoverPreviewCardMaterial,
            chromeTint: discoverPreviewCardTint,
            chromeBorder: discoverPreviewCardBorder,
            colorScheme: colorScheme,
            content: {
                venuePreviewCardScrollContent(resolved: resolved, gamesToday: gamesToday)
            },
            actions: {
                venuePreviewActionRow(bar: resolved)
            }
        )
        .onAppear {
            UIPerformanceDiagnostics.signpost(
                "Discover card open",
                "venueId=\(resolved.id.uuidString.lowercased()) games=\(gamesToday.count)"
            )
#if DEBUG
            print("[VenuePreviewScrollDebug] fullCardContentScrollable=true")
            print("[VenuePreviewScrollDebug] bottomActionsPinned=true")
            print("[VenuePreviewStabilityDebug] closeButtonRemoved=true")
            print("[VenuePreviewStabilityDebug] swipeDismissConfirmedRemoved=true")
            print("[VenuePreviewStabilityDebug] gameCount=\(gamesToday.count)")
#endif
        }
    }

    @ViewBuilder
    private func venuePreviewCardScrollContent(resolved: BarVenue, gamesToday: [SportsEvent]) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                venuePreviewCardStaticHeader(bar: resolved)

                Rectangle()
                    .fill(FGColor.divider(colorScheme))
                    .frame(height: 1)

                if let detailEvent = venuePreviewDetailEvent {
                    venuePreviewGameDetail(bar: resolved, event: detailEvent)
                } else {
                    let identityBanner = venuePreviewIdentityBannerModel(bar: resolved, gamesToday: gamesToday)
                    let fanZoneData = venuePreviewFanZoneData(bar: resolved, gamesToday: gamesToday)

                    venuePreviewIdentityBanner(identityBanner)

                    if resolved.isUnclaimedCommunityVenue {
                        UnclaimedBusinessStatusCard()
                        UnclaimedVenueSocialProofRow(
                            metrics: unclaimedVenueSocialProofMetrics(
                                for: resolved,
                                gamesToday: gamesToday,
                                fanZoneData: fanZoneData
                            )
                        )
                        UnclaimedBusinessClaimCallout {
                            requestUnclaimedVenueClaim(for: resolved)
                        }
                    }

                    venuePreviewFanZoneBlock(
                        fanZoneData,
                        bar: resolved,
                        gamesToday: gamesToday,
                        isUnclaimedBusiness: resolved.isUnclaimedCommunityVenue
                    )
                        .zIndex(5)

                    gamesListSection(bar: resolved, gamesToday: gamesToday)
                        .zIndex(0)
                }
            }
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func venuePreviewInfoRow(icon: String, title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: FGSpacing.sm) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(FGColor.accentBlue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(FGTypography.caption.weight(.bold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                Text(value)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(FGSpacing.md)
        .background(discoverPreviewInnerSurface)
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                .strokeBorder(discoverPreviewControlBorder.opacity(0.74), lineWidth: 1)
        }
    }

    private func venuePreviewIdentityBannerModel(
        bar: BarVenue,
        gamesToday: [SportsEvent]
    ) -> VenuePreviewIdentityBanner {
        let rawSupporterCountry = bar.supporterCountry?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !rawSupporterCountry.isEmpty {
            if let supporter = VenueSupporterCountryMode.display(for: rawSupporterCountry, languageCode: appLanguageRaw) {
                return VenuePreviewIdentityBanner(
                    rawIdentity: supporter.storedCountry,
                    displayName: supporter.countryName,
                    flag: supporter.flag
                )
            }
#if DEBUG
            print("[VenueSupporterIdentityDebug] backendGuard=invalid_db_value_ignored venueId=\(bar.id.uuidString.lowercased()) supporterCountry=\(rawSupporterCountry)")
#endif
            return VenuePreviewIdentityBanner(
                rawIdentity: nil,
                displayName: "FanGeo",
                flag: "🏟️"
            )
        }

        for event in gamesToday {
            let matchup = venuePreviewSafeMatchup(bar: bar, event: event)
            for identity in [matchup.home, matchup.away] {
                let theme = TeamTheme.resolve(identity)
                if !theme.usesFallback {
                    return VenuePreviewIdentityBanner(
                        rawIdentity: identity,
                        displayName: theme.displayName,
                        flag: theme.flag
                    )
                }
            }
        }

        logVenueGameCardCrashGuard(reason: gamesToday.isEmpty ? "identityFallbackNoGames" : "identityFallbackNoCountryTheme", venue: bar, event: nil)
        return VenuePreviewIdentityBanner(
            rawIdentity: nil,
            displayName: "FanGeo",
            flag: "🏟️"
        )
    }

    private func venuePreviewIdentityBanner(_ banner: VenuePreviewIdentityBanner) -> some View {
        let theme = TeamTheme.resolve(banner.rawIdentity)
        let flag = TeamTheme.safeFlag(banner.flag) ?? TeamTheme.safeFlag(theme.flag)
        let initials = String(banner.displayName.prefix(2)).uppercased()

        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.14 : 0.78))
                Circle()
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)

                if let flag {
                    Text(flag)
                        .font(.system(size: 34))
                        .shadow(color: .black.opacity(0.20), radius: 3, y: 2)
                } else {
                    Text(initials)
                        .font(.system(size: 17, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(banner.displayName) Watch Spot")
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
                    .shadow(color: .black.opacity(0.34), radius: 4, y: 2)

                Text("TOURNAMENT CROWD MODE")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.84))
                    .tracking(0.6)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background {
            ZStack {
                safeVenueGameGradient(
                    homeTheme: theme,
                    awayTheme: theme,
                    eventId: CountryTheme.normalize(banner.displayName),
                    cardVariant: "identityBanner"
                )
                LinearGradient(
                    colors: [
                        Color.black.opacity(colorScheme == .dark ? 0.10 : 0.02),
                        Color.black.opacity(colorScheme == .dark ? 0.40 : 0.26)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.05 : 0.08))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: theme.accent.opacity(colorScheme == .dark ? 0.30 : 0.18), radius: 16, y: 8)
        .onAppear {
#if DEBUG
            print("[VenueSupporterBannerDebug] venueLevelBanner=true")
            print("[VenueSupporterBannerDebug] identity=\(banner.rawIdentity ?? "fallback")")
            print("[VenueSupporterDebug] supporterBannerVisible=true")
#endif
        }
    }

    private func venuePreviewFanZoneData(
        bar: BarVenue,
        gamesToday: [SportsEvent]
    ) -> VenuePreviewFanZoneData {
        let cacheKey = venuePreviewFanZoneCacheKey(venueID: bar.id, date: viewModel.selectedDate)
        var eventIDs: [UUID] = []
        var seenEventIDs = Set<UUID>()

        for event in gamesToday {
            let gameTitle = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eventID = viewModel.peekVenueEventIDForRender(for: bar, gameTitle: gameTitle),
                  !seenEventIDs.contains(eventID) else {
                continue
            }
            seenEventIDs.insert(eventID)
            eventIDs.append(eventID)
        }

        var fireCount = 0
        var seatingCount = 0
        var tvCount = 0
        var audioCount = 0
        var crowdCount = 0
        var hasLoadedVibeState = false

        for eventID in eventIDs {
            if fanUpdatesStore.venueEventVibeCounts[eventID] != nil || fanUpdatesStore.myVenueEventVibes[eventID] != nil {
                hasLoadedVibeState = true
            }
            let counts = fanUpdatesStore.venueEventVibeCounts[eventID] ?? [:]
            fireCount += max(0, counts["packed"] ?? 0)
            seatingCount += max(0, counts["seats_open"] ?? 0)
            tvCount += max(0, counts["tv_visible"] ?? 0)
            audioCount += max(0, counts["audio_on"] ?? 0)
            crowdCount += max(0, counts["crowd"] ?? 0)
        }

        let targetEventID = eventIDs.first
        let selectedVibes = targetEventID.flatMap { fanUpdatesStore.myVenueEventVibes[$0] } ?? []
        let savingVibes = venuePreviewFanZoneSavingVibes(cacheKey: cacheKey)
        if (!savingVibes.isEmpty || !hasLoadedVibeState), let cached = venuePreviewFanZoneCache[cacheKey] {
#if DEBUG
            print("[VenueVibeLoadDebug] cacheHit venueId=\(bar.id.uuidString.lowercased()) date=\(venuePreviewFanZoneDateString(for: viewModel.selectedDate))")
#endif
            return VenuePreviewFanZoneData(
                cacheKey: cacheKey,
                venueID: bar.id,
                vibeTargetEventID: cached.vibeTargetEventID,
                eventIDs: cached.eventIDs,
                fireCount: cached.fireCount,
                seatingCount: cached.seatingCount,
                tvCount: cached.tvCount,
                audioCount: cached.audioCount,
                crowdCount: cached.crowdCount,
                selectedVibes: cached.selectedVibes,
                savingVibes: savingVibes,
                isFromCache: true
            )
        }

#if DEBUG
        if !hasLoadedVibeState {
            print("[VenueVibeLoadDebug] cacheMiss venueId=\(bar.id.uuidString.lowercased()) date=\(venuePreviewFanZoneDateString(for: viewModel.selectedDate))")
        }
#endif

        return VenuePreviewFanZoneData(
            cacheKey: cacheKey,
            venueID: bar.id,
            vibeTargetEventID: targetEventID,
            eventIDs: eventIDs,
            fireCount: fireCount,
            seatingCount: seatingCount,
            tvCount: tvCount,
            audioCount: audioCount,
            crowdCount: crowdCount,
            selectedVibes: selectedVibes,
            savingVibes: savingVibes,
            isFromCache: false
        )
    }

    private func unclaimedVenueSocialProofMetrics(
        for bar: BarVenue,
        gamesToday: [SportsEvent] = [],
        fanZoneData: VenuePreviewFanZoneData? = nil
    ) -> UnclaimedVenueSocialProofMetrics {
        var extraEventIDs = Set(fanZoneData?.eventIDs ?? [])
        for game in gamesToday {
            if let id = viewModel.peekVenueEventIDForRender(for: bar, gameTitle: game.title) {
                extraEventIDs.insert(id)
            }
        }
        let favoritedByFans: Int = {
            guard viewModel.currentUserHomeCrowdVenueId == bar.id else { return 0 }
            return max(0, viewModel.currentUserHomeCrowdVenue?.fanCount ?? 0)
        }()
        let previewVibeTotal = fanZoneData.map {
            $0.fireCount + $0.seatingCount + $0.tvCount + $0.audioCount + $0.crowdCount
        } ?? 0

        return UnclaimedVenueSocialProofBuilder.metrics(
            bar: bar,
            favoritedByFans: favoritedByFans,
            venueEventRows: viewModel.venueEventRows,
            extraEventIDs: Array(extraEventIDs),
            gamesTodayCount: gamesToday.count,
            interestCount: { viewModel.interestCountForVenueEvent($0) },
            commentCount: { viewModel.fanUpdatesDisplayCommentCount(for: $0) },
            vibeCounts: { fanUpdatesStore.venueEventVibeCounts[$0] ?? [:] },
            previewVibeTotal: previewVibeTotal
        )
    }

    private func venuePreviewFanZoneBlock(
        _ data: VenuePreviewFanZoneData,
        bar: BarVenue,
        gamesToday: [SportsEvent],
        isUnclaimedBusiness: Bool = false
    ) -> some View {
        let mapEnergyScore = viewModel.mapPinEnergyScore(bar: bar, gamesOnMapDay: gamesToday)
        let venueEnergyCaption = VenueEnergyEducation.displayLabel(forMapEnergyScore: mapEnergyScore)
        return VenuePreviewFanZoneBlockView(
            venueEnergyCaption: venueEnergyCaption.isEmpty ? nil : venueEnergyCaption,
            fireCount: data.fireCount,
            seatingCount: data.seatingCount,
            tvCount: data.tvCount,
            audioCount: data.audioCount,
            crowdCount: data.crowdCount,
            selectedVibes: data.selectedVibes,
            savingVibes: data.savingVibes,
            isVotingEnabled: data.vibeTargetEventID != nil,
            showsUnclaimedBusinessNote: isUnclaimedBusiness,
            onVote: { debugType, vibeType in
                venuePreviewToggleVenueLevelVibe(
                    data: data,
                    venueID: data.venueID,
                    eventID: data.vibeTargetEventID,
                    debugType: debugType,
                    vibeType: vibeType
                )
            }
        )
        .zIndex(5)
        .onAppear {
            venuePreviewStoreFanZoneCacheIfNeeded(data)
            venuePreviewRefreshVenueFanZoneVibesIfNeeded(data)
        }
        .onChange(of: data.fingerprint) { _, _ in
            venuePreviewStoreFanZoneCacheIfNeeded(data)
        }
    }

    private func venuePreviewFanZoneDateString(for date: Date) -> String {
        DiscoverPreviewDateFormatters.sqlDay.string(from: date)
    }

    private func venuePreviewFanZoneCacheKey(venueID: UUID, date: Date) -> String {
        "\(venueID.uuidString.lowercased())|\(venuePreviewFanZoneDateString(for: date))"
    }

    private func venuePreviewFanZoneSavingKey(cacheKey: String, vibeType: String) -> String {
        "\(cacheKey)|\(vibeType)"
    }

    private func venuePreviewFanZoneSavingVibes(cacheKey: String) -> Set<String> {
        let prefix = "\(cacheKey)|"
        return Set(venuePreviewFanZoneSavingKeys.compactMap { raw in
            raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : nil
        })
    }

    private func venuePreviewStoreFanZoneCacheIfNeeded(_ data: VenuePreviewFanZoneData) {
        guard !data.isFromCache else { return }
        venuePreviewFanZoneCache[data.cacheKey] = VenuePreviewFanZoneData(
            cacheKey: data.cacheKey,
            venueID: data.venueID,
            vibeTargetEventID: data.vibeTargetEventID,
            eventIDs: data.eventIDs,
            fireCount: data.fireCount,
            seatingCount: data.seatingCount,
            tvCount: data.tvCount,
            audioCount: data.audioCount,
            crowdCount: data.crowdCount,
            selectedVibes: data.selectedVibes,
            savingVibes: [],
            isFromCache: false
        )
    }

    private func venuePreviewRefreshVenueFanZoneVibesIfNeeded(_ data: VenuePreviewFanZoneData) {
        guard !data.eventIDs.isEmpty else { return }
        guard !venuePreviewFanZoneRefreshInFlightKeys.contains(data.cacheKey) else { return }
        venuePreviewFanZoneRefreshInFlightKeys.insert(data.cacheKey)
#if DEBUG
        print("[VenueVibeLoadDebug] refreshStarted venueId=\(data.venueID.uuidString.lowercased())")
#endif
        Task { @MainActor in
            for eventID in data.eventIDs {
                await viewModel.loadVibes(for: eventID)
            }
            venuePreviewFanZoneRefreshInFlightKeys.remove(data.cacheKey)
#if DEBUG
            print("[VenueVibeLoadDebug] refreshFinished venueId=\(data.venueID.uuidString.lowercased())")
#endif
        }
    }

    private func venuePreviewApplyOptimisticVenueFanZoneVibe(
        data: VenuePreviewFanZoneData,
        vibeType: String,
        selected: Bool
    ) {
        venuePreviewFanZoneSavingKeys.insert(venuePreviewFanZoneSavingKey(cacheKey: data.cacheKey, vibeType: vibeType))
        var selectedVibes = data.selectedVibes
        var fireCount = data.fireCount
        var seatingCount = data.seatingCount
        var tvCount = data.tvCount
        var audioCount = data.audioCount
        var crowdCount = data.crowdCount
        let delta = selected ? 1 : -1

        if selected {
            selectedVibes.insert(vibeType)
        } else {
            selectedVibes.remove(vibeType)
        }

        switch vibeType {
        case "packed":
            fireCount = max(0, fireCount + delta)
        case "seats_open":
            seatingCount = max(0, seatingCount + delta)
        case "tv_visible":
            tvCount = max(0, tvCount + delta)
        case "audio_on":
            audioCount = max(0, audioCount + delta)
        case "crowd":
            crowdCount = max(0, crowdCount + delta)
        default:
            break
        }

        venuePreviewFanZoneCache[data.cacheKey] = VenuePreviewFanZoneData(
            cacheKey: data.cacheKey,
            venueID: data.venueID,
            vibeTargetEventID: data.vibeTargetEventID,
            eventIDs: data.eventIDs,
            fireCount: fireCount,
            seatingCount: seatingCount,
            tvCount: tvCount,
            audioCount: audioCount,
            crowdCount: crowdCount,
            selectedVibes: selectedVibes,
            savingVibes: venuePreviewFanZoneSavingVibes(cacheKey: data.cacheKey),
            isFromCache: false
        )
    }

    private func venuePreviewToggleVenueLevelVibe(data: VenuePreviewFanZoneData, venueID: UUID, eventID: UUID?, debugType: String, vibeType: String) {
#if DEBUG
        print("[VenueVibeTapDebug] tapped type=\(debugType) venueId=\(venueID.uuidString.lowercased())")
#endif
        FGInteractionHaptics.softImpact()
        guard let eventID else { return }
        guard viewModel.isAuthenticatedForSocialFeatures else {
            viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
            return
        }
        guard viewModel.canUseFanSocialFeatures else {
            viewModel.logBusinessUserGateBlocked(action: "toggleVenueLevelVibe")
            fanFeatureGateAlertMessage = BusinessFanGateCopy.actionTapBlocked
            return
        }
        let previous = venuePreviewFanZoneCache[data.cacheKey] ?? data
        let nextSelected = !data.selectedVibes.contains(vibeType)
        venuePreviewApplyOptimisticVenueFanZoneVibe(data: data, vibeType: vibeType, selected: nextSelected)
#if DEBUG
        print("[VenueVibeTapDebug] optimisticApplied vibe=\(vibeType) selected=\(nextSelected)")
#endif
        Task {
            let success = await viewModel.toggleVibe(for: eventID, vibeType: vibeType)
            await MainActor.run {
                venuePreviewFanZoneSavingKeys.remove(venuePreviewFanZoneSavingKey(cacheKey: data.cacheKey, vibeType: vibeType))
                if success {
#if DEBUG
                    print("[VenueVibeTapDebug] saveSuccess vibe=\(vibeType)")
#endif
                } else {
                    venuePreviewFanZoneCache[data.cacheKey] = previous
#if DEBUG
                    print("[VenueVibeTapDebug] rollback vibe=\(vibeType)")
#endif
                }
            }
        }
    }

    @ViewBuilder
    private func venueHeroImage(_ bar: BarVenue) -> some View {
        let heroURLString = safeVenueHeroImageURLString(for: bar)
        let heroURL = heroURLString.flatMap(URL.init(string:))
        let fallbackUsed = heroURL == nil

        ZStack(alignment: .bottomLeading) {
            if let heroURL {
                DiscoverCachedRemoteImage(
                    url: heroURL,
                    contentMode: .fill,
                    venuePhotoDebugContext: VenuePhotoDebugContext(
                        venueId: bar.id,
                        venueName: bar.name,
                        selectedMainPhotoURL: heroURLString,
                        selectedSecondaryPhotoURL: selectedVenueSecondaryPhotoURLString(for: bar)
                    )
                ) {
                    venueHeroPlaceholder
                }
            } else {
                venueHeroPlaceholder
            }

            Text("Watch spot")
                .font(FGTypography.metadata.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.58))
                .clipShape(Capsule(style: .continuous))
                .padding(12)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 148)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onAppear {
#if DEBUG
            print("[VenuePreviewHeaderDebug] renderingHeroImage venueId=\(bar.id.uuidString.lowercased())")
            print("[VenuePreviewHeaderDebug] heroImageURL=\(heroURLString ?? "nil")")
            print("[VenuePreviewHeaderDebug] heroImageFallbackUsed=\(fallbackUsed)")
            print("[VenuePreviewHeaderDebug] photoArrowRemovedDueToCrash=true")
#endif
            logDiscoverCardPhotoDebug(bar: bar, urlString: heroURLString)
        }
    }

    private func safeVenueHeroImageURLString(for bar: BarVenue) -> String? {
        let trimmed = ImageDisplayURL.forList(
            thumbnail: bar.coverPhotoThumbnailURL,
            full: bar.coverPhotoURL
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = components.host,
              !host.isEmpty,
              URL(string: trimmed) != nil else {
            logVenueGameCardCrashGuard(reason: trimmed.isEmpty ? "venueHeroImageMissing" : "venueHeroImageInvalidURL", venue: bar, event: nil)
            return nil
        }
        return trimmed
    }

    private func selectedVenueSecondaryPhotoURLString(for bar: BarVenue) -> String? {
        ImageDisplayURL.forList(
            thumbnail: bar.menuPhotoThumbnailURL,
            full: bar.menuPhotoURL
        ) ?? ImageDisplayURL.forList(
            thumbnail: bar.coverPhotoThumbnailURL,
            full: bar.coverPhotoURL
        )
    }

    private func logDiscoverCardPhotoDebug(bar: BarVenue, urlString: String?) {
#if DEBUG
        let resolved = urlString ?? ""
        let thumbnail = bar.coverPhotoThumbnailURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let usingThumbnail = !thumbnail.isEmpty && resolved == thumbnail
        let selectedSecondary = selectedVenueSecondaryPhotoURLString(for: bar) ?? ""
        print("[VenuePhotoDebug] venueId=\(bar.id.uuidString.lowercased())")
        print("[VenuePhotoDebug] venueName=\(bar.name)")
        print("[VenuePhotoDebug] coverPhotoURL=\(bar.coverPhotoURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")")
        print("[VenuePhotoDebug] coverThumbnailURL=\(bar.coverPhotoThumbnailURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")")
        print("[VenuePhotoDebug] menuPhotoURL=\(bar.menuPhotoURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")")
        print("[VenuePhotoDebug] menuThumbnailURL=\(bar.menuPhotoThumbnailURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")")
        print("[VenuePhotoDebug] selectedMainPhotoURL=\(resolved)")
        print("[VenuePhotoDebug] selectedSecondaryPhotoURL=\(selectedSecondary)")
        print("[VenuePhotoDisplayDebug] discoverCardCoverURL=\(resolved)")
        print("[VenuePhotoDisplayDebug] usingThumbnail=\(usingThumbnail)")
        print("[VenuePhotoDisplayDebug] fallbackUsed=\(resolved.isEmpty)")
#endif
    }

    private func logVenueGameCardCrashGuard(reason: String, venue: BarVenue, event: SportsEvent?) {
#if DEBUG
        let venueName = venue.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let eventName = event?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? "nil"
        print("[VenueGameCardCrashGuard] reason=\(reason) venue=\(venueName.isEmpty ? venue.id.uuidString.lowercased() : venueName) event=\(eventName.isEmpty ? "empty" : eventName)")
#endif
    }

    private var venueHeroPlaceholder: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        FGColor.accentBlue.opacity(colorScheme == .dark ? 0.30 : 0.18),
                        FGColor.accentGreen.opacity(colorScheme == .dark ? 0.24 : 0.14)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Image(systemName: "building.2.crop.circle")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme).opacity(0.34))
            }
    }

    private func venuePreviewActionRow(bar: BarVenue) -> some View {
        HStack(spacing: FGSpacing.sm) {
            Button {
                viewModel.openDirections(to: bar)
            } label: {
                Label("Directions", systemImage: "location.fill")
                    .font(FGTypography.cardTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, FGSpacing.md)
                    .background(discoverPreviewControlBackground)
                    .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                            .strokeBorder(discoverPreviewControlBorder, lineWidth: 1)
                    }
            }
            .buttonStyle(FGPremiumPressButtonStyle(hapticOnPress: true))

            FGPrimaryButton(
                title: viewModel.isGuestDiscoverMode ? "View venue" : "Details",
                systemImage: viewModel.isGuestDiscoverMode ? "lock.fill" : nil
            ) {
                guard viewModel.canViewDiscoverDetails() else {
                    viewModel.showSocialActionToast("Sign in with a FanGeo account to view venue details.")
                    return
                }
                showVenueDetails = true
            }
        }
    }
    
    
    private func selectedEventSection(bar: BarVenue, selectedEvent: SportsEvent) -> some View {
        venuePreviewGameDetail(bar: bar, event: selectedEvent)
    }
    
    private func gamesListSection(bar: BarVenue, gamesToday: [SportsEvent]) -> some View {
        let orderedEvents = venuePreviewOrderedGames(bar: bar, gamesToday: gamesToday)
        let previewEvents = Array(orderedEvents.prefix(4))
        let stableItems = venuePreviewStableGameItems(for: previewEvents, selectedVenueID: bar.id)
        let hasViewAllGames = orderedEvents.count > previewEvents.count
        let _ = logVenueGameOrderDebug(events: orderedEvents, bar: bar)
        let _ = logVenuePreviewGameLimitDebug(
            totalGames: orderedEvents.count,
            renderedGames: previewEvents.count,
            hasViewAll: hasViewAllGames
        )

        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: FGSpacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Games at this venue")
                        .font(FGTypography.sectionTitle.weight(.bold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))

                    Spacer(minLength: 8)

                    if hasViewAllGames {
                        Button {
                            guard viewModel.canViewDiscoverDetails() || viewModel.isGuestDiscoverMode else {
                                viewModel.showSocialActionToast("Sign in with a FanGeo account to view venue details.")
                                return
                            }
                            showVenueDetails = true
                        } label: {
                            HStack(spacing: 4) {
                                Text("View all")
                                    .font(FGTypography.caption.weight(.bold))
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.bold))
                            }
                            .foregroundStyle(FGColor.accentBlue)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if viewModel.isLoadingEvents && gamesToday.isEmpty {
                    loadingVenueGamesView
                } else if gamesToday.isEmpty {
                    venuePreviewNoGamesForSelectedDayView(bar: bar)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(stableItems) { item in
#if DEBUG
                            let _ = logVenuePreviewModeDebug(renderingFullGameCard: true, eventTitle: item.event.title)
#endif
                            if item.index == 0 {
                                venuePreviewHeroGameCard(bar: bar, event: item.event)
                            } else {
                                venuePreviewCompactGameCard(bar: bar, event: item.event)
                            }
                        }

                        if hasViewAllGames {
                            venuePreviewViewAllGamesRow(totalGames: orderedEvents.count)
                        }
                    }
                }
            }
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onAppear {
#if DEBUG
                    print("[VenueGameCardUI] separatedGameCards=true")
                    print("[VenuePreviewStabilityDebug] inlineAdInjectionDisabled=true")
                    print("[VenuePreviewStabilityDebug] stableGameForEach=true")
                    print("[VenuePreviewStabilityDebug] gameCount=\(gamesToday.count)")
#endif
                }

            if viewModel.isRefreshingDiscoverEvents && !gamesToday.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 2)
            }
        }
    }

    private func venuePreviewViewAllGamesRow(totalGames: Int) -> some View {
        Button {
            guard viewModel.canViewDiscoverDetails() || viewModel.isGuestDiscoverMode else {
                viewModel.showSocialActionToast("Sign in with a FanGeo account to view venue details.")
                return
            }
            showVenueDetails = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet.rectangle.portrait.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FGColor.accentBlue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("View all games")
                        .font(FGTypography.cardTitle.weight(.bold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text("\(totalGames) games at this venue")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.10 : 0.06))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.20 : 0.14), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("View all \(totalGames) games")
    }

    private func logVenuePreviewGameLimitDebug(totalGames: Int, renderedGames: Int, hasViewAll: Bool) {
#if DEBUG
        print("[VenuePreviewGameLimitDebug] totalGames=\(totalGames)")
        print("[VenuePreviewGameLimitDebug] renderedGames=\(renderedGames)")
        print("[VenuePreviewGameLimitDebug] hasViewAll=\(hasViewAll)")
#endif
    }

    private func venuePreviewHeroGameCard(
        bar: BarVenue,
        event: SportsEvent,
        showsAttendanceFooter: Bool = true
    ) -> some View {
        let uiPerfStart = UIPerformanceDiagnostics.timestamp()
        let safeTitle = event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Game"
            : event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeSport = event.sport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Sport"
            : event.sport.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeBadgeLabel = safeSport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "SPORT"
            : safeSport.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let sportDisplay = venuePreviewSportDisplayModel(sport: safeSport, league: event.league)
        let venueEventID = viewModel.peekVenueEventIDForRender(for: bar, gameTitle: safeTitle)
        let rowMatchup = venueEventID.flatMap { resolvedID -> VenuePreviewMatchup? in
            guard let row = viewModel.venueEventRows.first(where: { $0.id == resolvedID }),
                  let home = trimmedNonEmpty(row.home_team),
                  let away = trimmedNonEmpty(row.away_team) else {
                return nil
            }
            return VenuePreviewMatchup(home: home, away: away, hasResolvedTeams: true)
        }
        let matchup = rowMatchup ?? venuePreviewSafeMatchup(bar: bar, event: event)
        let safeHomeTitle = matchup.hasResolvedTeams && !matchup.home.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? matchup.home.trimmingCharacters(in: .whitespacesAndNewlines)
            : "Home"
        let safeAwayTitle = matchup.hasResolvedTeams && !matchup.away.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? matchup.away.trimmingCharacters(in: .whitespacesAndNewlines)
            : "Away"
        let safeHomeTheme = TeamTheme.resolve(safeHomeTitle)
        let safeAwayTheme = TeamTheme.resolve(safeAwayTitle)
        let displayTitles = venuePreviewMatchupDisplayTitles(
            matchup: matchup,
            eventTitle: safeTitle,
            homeTheme: safeHomeTheme,
            awayTheme: safeAwayTheme
        )
        let displayTime = venuePreviewGameDateTimeText(for: event)
        let eventID = event.id.uuidString.lowercased()
        let chatTitle = "\(venuePreviewHeroChatTitle(matchup: matchup, fallbackTitle: safeTitle)) Fan Chat"
        let attendancePresentation = showsAttendanceFooter
            ? venuePreviewAttendancePresentation(bar: bar, event: event, venueEventID: venueEventID)
            : nil
        let alreadyInterested = attendancePresentation?.alreadyInterested ?? false
        let safeGoingCount = max(0, attendancePresentation?.goingCount ?? 0)
        let safeGoingAvatarProfiles = venuePreviewVisibleGoingAvatarProfiles(
            attendancePresentation?.avatarProfiles ?? []
        )
        let predictionVisibility = venuePredictionVisibility(
            bar: bar,
            event: event,
            venueEventID: venueEventID
        )
        let predictionSummary = venueEventID.flatMap { viewModel.venueEventPredictionSummaries[$0] }
        let fanChatCount = venueEventID.map { viewModel.fanUpdatesDisplayCommentCount(for: $0) } ?? 0
        let goingIsPending = venueEventID.map { viewModel.isVenueEventInterestMutationInFlight($0) } ?? false
        let goingIsDisabled = venueEventID == nil || goingIsPending
        let showsPredictionRow =
            showsAttendanceFooter
            && predictionVisibility.shouldRender
            && predictionVisibility.eventID != nil
            && predictionVisibility.teams != nil
            && venuePredictionSportIsSupported(predictionVisibility.sportType)
        let predictionVoteCount = predictionSummary?.totalCount ?? 0
        let predictionConsensusText = venuePreviewProHeroPredictionConsensusText(summary: predictionSummary)

        let card = VenuePreviewProHeroGameCard(
            homeTheme: safeHomeTheme,
            awayTheme: safeAwayTheme,
            homeTitle: displayTitles.home,
            awayTitle: displayTitles.away,
            hasResolvedTeams: matchup.hasResolvedTeams,
            fallbackTitle: safeTitle,
            sportLabel: safeBadgeLabel,
            sportIconName: sportDisplay.iconName,
            dateTimeText: displayTime,
            eventId: eventID,
            goingCount: safeGoingCount,
            avatarProfiles: safeGoingAvatarProfiles,
            viewerUserID: viewModel.currentUserAuthId,
            showsGoingSection: showsAttendanceFooter,
            goingAlreadyInterested: alreadyInterested,
            goingIsPending: goingIsPending,
            goingIsDisabled: goingIsDisabled,
            chatCommentCount: fanChatCount,
            chatIsDisabled: venueEventID == nil,
            showsPredictionRow: showsPredictionRow,
            predictionVoteCount: predictionVoteCount,
            predictionConsensusText: predictionConsensusText,
            showsGuestInteraction: viewModel.isGuestDiscoverMode,
            languageCode: L10n.normalizedLanguageCode(appLanguageRaw),
            onCardTap: {
                FGInteractionHaptics.softImpact()
                openVenuePreviewGameDetail(event)
            },
            onGoingTap: {
                guard venueEventID != nil else { return }
                FGInteractionHaptics.softImpact()
                viewModel.toggleVenueGameGoingFromUI(
                    bar: bar,
                    gameTitle: event.title,
                    eventDate: event.date,
                    knownVenueEventID: venueEventID,
                    source: "discoverVenueHeroGoingButton",
                    onRequiresLogin: {
                        viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
                    },
                    onBusinessBlocked: {
                        viewModel.logBusinessUserGateBlocked(action: "markGoing")
                        fanFeatureGateAlertMessage = BusinessFanGateCopy.actionTapBlocked
                    }
                )
            },
            onChatTap: {
                guard let venueEventID else { return }
                FGInteractionHaptics.selection()
                presentFanUpdatesSheet(venueEventID: venueEventID, title: chatTitle)
            },
            onPredictionTap: {
                FGInteractionHaptics.softImpact()
                openVenuePreviewGameDetail(event)
            },
            onGuestCreateAccount: {
                pendingResumeVenueIDAfterLogin = bar.id
                viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: true)
            },
            onGuestSignIn: {
                pendingResumeVenueIDAfterLogin = bar.id
                viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
            }
        )
        .onAppear {
#if DEBUG
            print("[HeroCardFallbackDebug] renderingSafeHeroCard eventId=\(eventID)")
            print("[HeroCardRebuildDebug] step=sportBadge eventId=\(eventID)")
            print("[HeroCardRebuildDebug] step=teamNames eventId=\(eventID)")
            print("[HeroCardRebuildDebug] step=initialsOrb eventId=\(eventID)")
            print("[HeroCardRebuildDebug] step=footer eventId=\(eventID)")
            print("[HeroCardRebuildDebug] step=teamColors eventId=\(eventID)")
            print("[HeroCardRebuildDebug] step=safeGradient eventId=\(eventID)")
            print("[HeroCardRebuildDebug] step=fanChatButton eventId=\(eventID)")
            print("[HeroCardRebuildDebug] step=goingButton eventId=\(eventID)")
            print("[HeroCardLayoutDebug] step=fanChatBesideGoing eventId=\(eventID)")
            print("[HeroCardLayoutDebug] variant=hero eventId=\(eventID)")
            print("[HeroCardRebuildDebug] step=safeFlags eventId=\(eventID)")
            print("[GoingPreviewDebug] count=\(safeGoingCount) avatarCount=\(safeGoingAvatarProfiles.count)")
#endif
        }

        let bodyBuildMs = UIPerformanceDiagnostics.elapsedMs(since: uiPerfStart)
        UIPerformanceDiagnostics.log("venueCardBodyBuild eventId=\(eventID) ms=\(UIPerformanceDiagnostics.formattedMs(bodyBuildMs)) variant=hero")
        UIPerformanceDiagnostics.logDiscoverScrollFrameDropIfNeeded(
            elapsedMs: bodyBuildMs,
            source: "venueCardBodyBuild",
            eventId: eventID
        )

        return card
    }

    private func venuePreviewProHeroGoingButton(
        bar: BarVenue,
        event: SportsEvent,
        venueEventID: UUID?,
        alreadyInterested: Bool
    ) -> some View {
        let isPending = venueEventID.map { viewModel.isVenueEventInterestMutationInFlight($0) } ?? false
        let isDisabled = venueEventID == nil || isPending
        let fill = alreadyInterested
            ? LinearGradient(
                colors: [Color(red: 0.00, green: 0.72, blue: 0.34), Color(red: 0.00, green: 0.52, blue: 0.24)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            : LinearGradient(
                colors: [
                    FGColor.accentGreen.opacity(colorScheme == .dark ? 0.22 : 0.14),
                    FGColor.accentGreen.opacity(colorScheme == .dark ? 0.14 : 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        let foreground = alreadyInterested ? Color.white : FGColor.accentGreen

        return Button {
            guard venueEventID != nil else { return }
            FGInteractionHaptics.softImpact()
            viewModel.toggleVenueGameGoingFromUI(
                bar: bar,
                gameTitle: event.title,
                eventDate: event.date,
                knownVenueEventID: venueEventID,
                source: "discoverVenueHeroGoingButton",
                onRequiresLogin: {
                    viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
                },
                onBusinessBlocked: {
                    viewModel.logBusinessUserGateBlocked(action: "markGoing")
                    fanFeatureGateAlertMessage = BusinessFanGateCopy.actionTapBlocked
                }
            )
        } label: {
            HStack(spacing: 6) {
                if isPending {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(foreground)
                } else {
                    Image(systemName: alreadyInterested ? "checkmark" : "plus")
                        .font(.caption.weight(.black))
                }
                Text(alreadyInterested ? "Going" : "Going?")
                    .font(FGTypography.metadata.weight(.heavy))
                    .lineLimit(1)
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background {
                Capsule(style: .continuous)
                    .fill(fill)
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(FGColor.accentGreen.opacity(alreadyInterested ? 0.36 : 0.24), lineWidth: 1)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.68 : 1)
        .accessibilityLabel(alreadyInterested ? "Going" : "Mark as going")
    }

    private func venuePreviewProHeroChatButton(
        venueEventID: UUID?,
        title: String,
        commentCount: Int
    ) -> some View {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let chatTitle = trimmedTitle.isEmpty ? "Game Fan Chat" : trimmedTitle
        let isDisabled = venueEventID == nil

        return Button {
            guard let venueEventID else { return }
            FGInteractionHaptics.selection()
            presentFanUpdatesSheet(venueEventID: venueEventID, title: chatTitle)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.caption.weight(.bold))
                Text("Chat")
                    .font(FGTypography.metadata.weight(.heavy))
                    .lineLimit(1)
                if commentCount > 0 {
                    Circle()
                        .fill(FGColor.accentBlue)
                        .frame(width: 7, height: 7)
                }
            }
            .foregroundStyle(.white.opacity(0.92))
            .frame(maxWidth: .infinity, minHeight: 40)
            .background {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.14 : 0.10),
                                Color.black.opacity(colorScheme == .dark ? 0.34 : 0.28)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.12), lineWidth: 1)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.62 : 1)
        .accessibilityLabel(
            commentCount > 0
                ? "Chat, \(commentCount) comments"
                : chatTitle
        )
    }

    @ViewBuilder
    private func venuePreviewProHeroPredictionRow(
        event: SportsEvent,
        visibility: DiscoverVenuePredictionVisibility,
        summary: VenueEventPredictionSummary?
    ) -> some View {
        if visibility.shouldRender,
           visibility.eventID != nil,
           visibility.teams != nil,
           venuePredictionSportIsSupported(visibility.sportType) {
            let voteCount = summary?.totalCount ?? 0
            let consensusText = venuePreviewProHeroPredictionConsensusText(summary: summary)

            Button {
                FGInteractionHaptics.softImpact()
                openVenuePreviewGameDetail(event)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "trophy.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(FGColor.accentYellow)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fan Predictions")
                            .font(FGTypography.caption.weight(.heavy))
                            .foregroundStyle(.white.opacity(0.94))
                            .lineLimit(1)

                        if let consensusText {
                            Text(consensusText)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.58))
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                        }
                    }

                    Spacer(minLength: 6)

                    if voteCount > 0 {
                        Text(voteCount == 1 ? "1 fan voted" : "\(voteCount) fans voted")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                    }

                    Text("Open")
                        .font(FGTypography.caption.weight(.bold))
                        .foregroundStyle(FGColor.accentGreen)

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(FGColor.accentGreen.opacity(0.88))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.07 : 0.06))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.08), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func venuePreviewProHeroPredictionConsensusText(
        summary: VenueEventPredictionSummary?
    ) -> String? {
        guard let summary,
              let leader = summary.winnerLeader?.trimmingCharacters(in: .whitespacesAndNewlines),
              !leader.isEmpty else {
            return nil
        }

        let displayLeader: String = {
            if leader.caseInsensitiveCompare("Draw") == .orderedSame {
                return "Draw"
            }
            return leader
        }()

        if let percent = summary.winnerPercent, percent > 0 {
            return "\(displayLeader) favored by fans (\(percent)%)"
        }
        return "\(displayLeader) favored by fans"
    }

    private func venuePreviewFanChatChip(venueEventID: UUID?, chatTitle: String) -> some View {
        let isDisabled = venueEventID == nil
        return Button {
            guard let venueEventID else { return }
            FGInteractionHaptics.selection()
            presentFanUpdatesSheet(venueEventID: venueEventID, title: chatTitle)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.caption.weight(.bold))
                Text("Chat")
                    .font(FGTypography.caption.weight(.heavy))
                    .lineLimit(1)
            }
            .foregroundStyle(FGColor.accentBlue)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.16 : 0.10))
            .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
    }

    private func venuePreviewSafeTextFooter(
        bar: BarVenue,
        event: SportsEvent,
        venueEventID: UUID?,
        alreadyInterested: Bool,
        chatTitle: String,
        goingCount: Int,
        avatarProfiles: [UserProfileRow]
    ) -> some View {
        return venuePreviewGameSocialFooter(
            bar: bar,
            event: event,
            venueEventID: venueEventID,
            chatTitle: chatTitle,
            alreadyInterested: alreadyInterested,
            avatarProfiles: avatarProfiles,
            goingCount: goingCount,
            avatarDiameter: 26,
            textFont: FGTypography.caption.weight(.semibold)
        )
    }

    private func venuePreviewGoingCTA(
        bar: BarVenue,
        event: SportsEvent,
        venueEventID: UUID?,
        alreadyInterested: Bool
    ) -> some View {
        let isPending = venueEventID.map { viewModel.isVenueEventInterestMutationInFlight($0) } ?? false
        let isDisabled = venueEventID == nil || isPending
        let title = isPending ? "Saving..." : (alreadyInterested ? "Going" : "I’m Going")

        return Button {
            guard venueEventID != nil else { return }
            FGInteractionHaptics.softImpact()
            viewModel.toggleVenueGameGoingFromUI(
                bar: bar,
                gameTitle: event.title,
                eventDate: event.date,
                knownVenueEventID: venueEventID,
                source: "discoverVenueHeroGoingButton",
                onRequiresLogin: {
                    viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
                },
                onBusinessBlocked: {
                    viewModel.logBusinessUserGateBlocked(action: "markGoing")
                    fanFeatureGateAlertMessage = BusinessFanGateCopy.actionTapBlocked
                }
            )
        } label: {
            Text(title)
                .font(FGTypography.caption.weight(.heavy))
                .foregroundStyle(alreadyInterested ? Color.white : FGColor.accentGreen)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background {
                    Capsule(style: .continuous)
                        .fill(alreadyInterested ? Color(red: 0.00, green: 0.62, blue: 0.27) : FGColor.accentGreen.opacity(colorScheme == .dark ? 0.18 : 0.12))
                }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.62 : 1)
    }

    @ViewBuilder
    private func venuePreviewGoingAvatarPreview(_ profiles: [UserProfileRow]) -> some View {
        let previewProfiles = Array(profiles.prefix(3))
        if !previewProfiles.isEmpty {
            HStack(spacing: -6) {
                ForEach(Array(previewProfiles.enumerated()), id: \.offset) { _, profile in
                    venuePreviewMiniGoingAvatar(profile)
                }
            }
            .accessibilityHidden(true)
            .onAppear {
#if DEBUG
                print("[GoingAvatarDebug] count=\(previewProfiles.count)")
#endif
            }
        }
    }

    private func venuePreviewMiniGoingAvatar(_ profile: UserProfileRow) -> some View {
        let avatar = venuePreviewMiniGoingAvatarDisplay(profile)
#if DEBUG
        print("[GoingAvatarDebug] usingThumbnail=\(avatar.usingThumbnail)")
        print("[GoingAvatarDebug] fallbackInitials=\(avatar.url == nil)")
#endif

        return ZStack {
            if let url = avatar.url {
                CachedRemoteImagePhaseView(url: url, bucket: .avatar) { phase in
                    switch phase {
                    case .success(let uiImage):
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                    case .empty, .failure:
                        venuePreviewMiniGoingAvatarInitials(avatar.initials)
                            .onAppear {
#if DEBUG
                                print("[GoingAvatarDebug] fallbackInitials=true")
#endif
                            }
                    }
                }
            } else {
                venuePreviewMiniGoingAvatarInitials(avatar.initials)
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(FGColor.cardBackground(colorScheme), lineWidth: 1.5)
        }
    }

    private func venuePreviewMiniGoingAvatarInitials(_ initials: String) -> some View {
        Text(initials)
            .font(.system(size: 9, weight: .black, design: .rounded))
            .foregroundStyle(FGColor.primaryText(colorScheme))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.26 : 0.16))
    }

    private func venuePreviewMiniGoingAvatarDisplay(_ profile: UserProfileRow) -> (url: URL?, usingThumbnail: Bool, initials: String) {
        let displayName = profile.display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let username = profile.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let initialsSource = !displayName.isEmpty ? displayName : (!username.isEmpty ? username : "F")
        let initials = venuePreviewSafeInitials(initialsSource)
        let thumbnail = ImageDisplayURL.canonicalStorageURLString(profile.avatar_thumbnail_url)
        let full = ImageDisplayURL.canonicalStorageURLString(profile.avatar_url)
        let rawURL: String?
        let usingThumbnail: Bool
        if !thumbnail.isEmpty {
            rawURL = thumbnail
            usingThumbnail = true
        } else if !full.isEmpty {
            rawURL = full
            usingThumbnail = false
        } else {
            rawURL = nil
            usingThumbnail = false
        }

        let url = rawURL.flatMap(URL.init(string:))
        return (url, usingThumbnail, initials.isEmpty ? "F" : initials)
    }

    private func venuePreviewVisibleGoingAvatarProfiles(_ profiles: [UserProfileRow]) -> [UserProfileRow] {
        profiles.filter {
            !$0.isDeletedAccount && $0.isFanVisibleForLivePresence(to: viewModel.currentUserAuthId)
        }
    }

    private func venuePreviewInitialsOrb(_ initials: String, fill: Color, flag: String? = nil) -> some View {
        ZStack {
            Circle()
                .fill(fill)

            if let flag {
                Text(flag)
                    .font(.system(size: 17))
            } else {
                Text(initials)
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)
    }

    private func venuePreviewSafeHeroTeamFlag(team: String) -> (flag: String?, hasFlag: Bool, usedFlag: Bool, fallbackInitials: Bool) {
        let safeTeam = team.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTeam = CountryTheme.normalize(safeTeam)
        let rawFlag = safeTeam.isEmpty ? nil : TeamTheme.resolve(safeTeam).flag
        let trimmedFlag = rawFlag?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasFlag = !trimmedFlag.isEmpty
        let flag = venuePreviewStrictSafeFlag(trimmedFlag)
        let usedFlag = flag != nil
        let fallbackInitials = !usedFlag
        let fallbackReason: String = {
            if safeTeam.isEmpty { return "emptyTeam" }
            if !hasFlag { return "noResolvedFlag" }
            if !usedFlag { return "invalidFlag" }
            return "none"
        }()
#if DEBUG
        print("[FlagRenderDebug] team=\(safeTeam) hasFlag=\(hasFlag) usedFlag=\(usedFlag) fallbackInitials=\(fallbackInitials)")
        print("[FlagRenderDebug] normalizedTeam=\(normalizedTeam)")
        print("[FlagRenderDebug] resolvedFlag=\(flag ?? "nil")")
        print("[FlagRenderDebug] fallbackReason=\(fallbackReason)")
#endif
        return (flag, hasFlag, usedFlag, fallbackInitials)
    }

    private func venuePreviewStrictSafeFlag(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.unicodeScalars.count <= 8 else { return nil }
        guard !trimmed.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) || $0.value == 0xfffd
        }) else {
            return nil
        }
        return TeamTheme.safeFlag(trimmed)
    }

    private func venuePreviewSafeTeamOrbColor(team: String) -> (color: Color, fallbackUsed: Bool) {
        let safeTeam = team.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeTeam.isEmpty else {
#if DEBUG
            print("[TeamColorDebug] team= fallbackUsed=true")
#endif
            return (FGColor.accentGreen, true)
        }

        let theme = TeamTheme.resolve(safeTeam)
        let fallbackUsed = theme.usesFallback
        let color = fallbackUsed ? FGColor.accentGreen : theme.accentColor
#if DEBUG
        print("[TeamColorDebug] team=\(safeTeam) fallbackUsed=\(fallbackUsed)")
#endif
        return (color, fallbackUsed)
    }

    private func venuePreviewSafeInitials(_ raw: String) -> String {
        let letters = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { $0.isLetter || $0.isNumber }
        let initials = String(letters.prefix(2)).uppercased()
        return initials.isEmpty ? "FG" : initials
    }

    private func venuePreviewHeroCardPresentation(
        bar: BarVenue,
        event: SportsEvent
    ) -> VenuePreviewHeroCardPresentation {
        let gameTitle = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeGameTitle = gameTitle.isEmpty ? "Game" : gameTitle
        let venueEventID = viewModel.peekVenueEventIDForRender(for: bar, gameTitle: safeGameTitle)
        let matchup = venuePreviewSafeMatchup(bar: bar, event: event)
        let sport = event.sport.trimmingCharacters(in: .whitespacesAndNewlines)
        let league = event.league.trimmingCharacters(in: .whitespacesAndNewlines)
        if sport.isEmpty || SportFilterCatalog.isFallbackSport(sport) {
            logDiscoverPreviewCrashGuard(reason: sport.isEmpty ? "emptySport" : "unknownSport", sport: sport, team: "\(matchup.home)|\(matchup.away)")
        }
        let homeTheme = TeamTheme.resolve(matchup.home)
        let awayTheme = TeamTheme.resolve(matchup.away)
        let sportDisplay = venuePreviewSportDisplayModel(sport: sport, league: league)
        let renderID = venueEventID?.uuidString.lowercased() ?? event.id.uuidString.lowercased()
        let renderKey = "\(bar.id.uuidString.lowercased())|\(renderID)|\(safeGameTitle)"
        let chatTitle = "\(venuePreviewHeroChatTitle(matchup: matchup, fallbackTitle: safeGameTitle)) Fan Chat"

        return VenuePreviewHeroCardPresentation(
            renderKey: renderKey,
            gameTitle: safeGameTitle,
            sport: sport,
            league: league,
            sportDisplay: sportDisplay,
            dateTimeText: venuePreviewGameDateTimeText(for: event),
            chatTitle: chatTitle,
            venueEventID: venueEventID,
            matchup: matchup,
            homeTheme: homeTheme,
            awayTheme: awayTheme,
            homeOrb: venuePreviewTeamOrbDisplayModel(theme: homeTheme),
            awayOrb: venuePreviewTeamOrbDisplayModel(theme: awayTheme),
            homeTitle: venuePreviewSafeHeroTitle(homeTheme.uppercaseTitle),
            awayTitle: venuePreviewSafeHeroTitle(awayTheme.uppercaseTitle)
        )
    }

    private func venuePreviewSafeHeroTitle(_ rawTitle: String) -> String {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
#if DEBUG
            print("[VenueHeroCrashDebug] nil event/theme emptyHeroTitle=true")
#endif
            return "TEAM"
        }
        return trimmed
    }

    private func venuePreviewHeroChatTitle(matchup: VenuePreviewMatchup, fallbackTitle: String) -> String {
        if matchup.hasResolvedTeams {
            return "\(matchup.home) vs \(matchup.away)"
        }
        let trimmedFallback = fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedFallback.isEmpty ? "Game" : trimmedFallback
    }

    private func logVenueHeroCrashDebugOnAppear(
        presentation: VenuePreviewHeroCardPresentation,
        bar: BarVenue,
        event: SportsEvent
    ) {
#if DEBUG
        VenueHeroCrashDebugTracker.recordAppearance(renderKey: presentation.renderKey)

        if presentation.venueEventID == nil {
            print("[VenueHeroCrashDebug] nil event/theme venueEventID=nil renderKey=\(presentation.renderKey)")
        }
        if !presentation.matchup.hasResolvedTeams {
            print("[VenueHeroCrashDebug] invalid matchup unresolved title=\(presentation.gameTitle)")
        }
        if presentation.homeTheme.usesFallback || presentation.awayTheme.usesFallback {
            print("[VenueHeroCrashDebug] nil event/theme fallbackTheme home=\(presentation.homeTheme.usesFallback) away=\(presentation.awayTheme.usesFallback)")
        }
        if let selected = viewModel.selectedBar, selected.id != bar.id {
            print("[VenueHeroCrashDebug] annotation reuse anomaly selectedVenue=\(selected.id.uuidString.lowercased()) cardVenue=\(bar.id.uuidString.lowercased()) event=\(event.id.uuidString.lowercased())")
        }
#endif
    }

    private func venuePreviewCompactGameCard(bar: BarVenue, event: SportsEvent) -> some View {
        let uiPerfStart = UIPerformanceDiagnostics.timestamp()
        let gameTitle = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let venueEventID = viewModel.peekVenueEventIDForRender(for: bar, gameTitle: gameTitle)
        let presentation = venuePreviewAttendancePresentation(bar: bar, event: event, venueEventID: venueEventID)
        let rowMatchup = venueEventID.flatMap { resolvedID -> VenuePreviewMatchup? in
            guard let row = viewModel.venueEventRows.first(where: { $0.id == resolvedID }),
                  let home = trimmedNonEmpty(row.home_team),
                  let away = trimmedNonEmpty(row.away_team) else {
                return nil
            }
            return VenuePreviewMatchup(home: home, away: away, hasResolvedTeams: true)
        }
        let matchup = rowMatchup ?? venuePreviewSafeMatchup(bar: bar, event: event)
        let homeTheme = TeamTheme.resolve(matchup.home)
        let awayTheme = TeamTheme.resolve(matchup.away)
        let sportDisplay = venuePreviewSportDisplayModel(sport: event.sport, league: event.league)
        let eventID = venueEventID?.uuidString.lowercased() ?? event.id.uuidString.lowercased()
        let displayTitles = venuePreviewMatchupDisplayTitles(
            matchup: matchup,
            eventTitle: event.title,
            homeTheme: homeTheme,
            awayTheme: awayTheme
        )
        let statusTitle = venuePreviewGameStatusTitle(bar: bar, event: event, venueEventID: venueEventID)

        let card = VenueMatchupCardView(
            homeTheme: homeTheme,
            awayTheme: awayTheme,
            homeTitle: displayTitles.home,
            awayTitle: displayTitles.away,
            sportLabel: sportDisplay.badgeLabel,
            sportIconName: sportDisplay.iconName,
            dateTimeText: venuePreviewGameDateTimeText(for: event),
            statusTitle: statusTitle,
            statusTint: venuePreviewGameStatusTint(statusTitle),
            eventId: eventID,
            cardVariant: "compact",
            height: 166,
            cornerRadius: 24
        )
        .onTapGesture {
            FGInteractionHaptics.softImpact()
            openVenuePreviewGameDetail(event)
        }

        let bodyBuildMs = UIPerformanceDiagnostics.elapsedMs(since: uiPerfStart)
        UIPerformanceDiagnostics.log("venueCardBodyBuild eventId=\(eventID) ms=\(UIPerformanceDiagnostics.formattedMs(bodyBuildMs)) variant=compact")
        UIPerformanceDiagnostics.logDiscoverScrollFrameDropIfNeeded(
            elapsedMs: bodyBuildMs,
            source: "venueCardBodyBuild",
            eventId: eventID
        )

        return VStack(spacing: 0) {
            card

            venuePreviewAttendanceFooter(
                bar: bar,
                event: event,
                venueEventID: presentation.venueEventID,
                chatTitle: "\(venuePreviewFanChatMatchupTitle(bar: bar, event: event)) Fan Chat",
                alreadyInterested: presentation.alreadyInterested,
                avatarProfiles: presentation.avatarProfiles,
                goingCount: presentation.goingCount,
                avatarDiameter: 26,
                textFont: FGTypography.caption.weight(.semibold)
            )
        }
    }

    private func venuePreviewAttendanceFooter(
        bar: BarVenue,
        event: SportsEvent,
        venueEventID: UUID?,
        chatTitle: String,
        alreadyInterested: Bool,
        avatarProfiles: [UserProfileRow],
        goingCount: Int,
        avatarDiameter: CGFloat,
        textFont: Font
    ) -> some View {
        return venuePreviewGameSocialFooter(
            bar: bar,
            event: event,
            venueEventID: venueEventID,
            chatTitle: chatTitle,
            alreadyInterested: alreadyInterested,
            avatarProfiles: avatarProfiles,
            goingCount: goingCount,
            avatarDiameter: avatarDiameter,
            textFont: textFont
        )
    }

    @ViewBuilder
    private func venuePreviewGameSocialFooter(
        bar: BarVenue,
        event: SportsEvent,
        venueEventID: UUID?,
        chatTitle: String,
        alreadyInterested: Bool,
        avatarProfiles: [UserProfileRow],
        goingCount: Int,
        avatarDiameter: CGFloat,
        textFont: Font
    ) -> some View {
        let avatarPreviewProfiles = Array(venuePreviewVisibleGoingAvatarProfiles(avatarProfiles).prefix(4))
        let eventID = venueEventID?.uuidString.lowercased() ?? event.id.uuidString.lowercased()

        if viewModel.isGuestDiscoverMode {
            GuestGameInteractionSection(
                languageCode: L10n.normalizedLanguageCode(appLanguageRaw),
                onCreateAccount: {
                    pendingResumeVenueIDAfterLogin = bar.id
                    viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: true)
                },
                onSignIn: {
                    pendingResumeVenueIDAfterLogin = bar.id
                    viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
                },
                usesDarkHeroChrome: false
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.12 : 0.06))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.22 : 0.14), lineWidth: 1)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
        } else {
            HStack(spacing: 10) {
                venuePreviewGoingFooterButton(
                    bar: bar,
                    event: event,
                    venueEventID: venueEventID,
                    alreadyInterested: alreadyInterested
                )

                venuePreviewChatFooterButton(
                    venueEventID: venueEventID,
                    title: chatTitle
                )

                Spacer(minLength: 10)

                HStack(spacing: 8) {
                    if !avatarPreviewProfiles.isEmpty {
                        GoingAvatarStack(
                            profiles: avatarPreviewProfiles,
                            viewerUserID: viewModel.currentUserAuthId,
                            diameter: avatarDiameter
                        )
                    }

                    Text(venuePreviewGoingCountText(goingCount))
                        .font(textFont)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                .frame(minWidth: 78, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 56)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.14 : 0.08))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.26 : 0.18), lineWidth: 1)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .onAppear {
#if DEBUG
                print("[HeroCardLayoutDebug] socialRowAligned eventId=\(eventID)")
#endif
            }
        }
    }

    private func venuePreviewChatFooterButton(venueEventID: UUID?, title: String) -> some View {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let chatTitle = trimmedTitle.isEmpty ? "Game Fan Chat" : trimmedTitle
        let isDisabled = venueEventID == nil

        return Button {
            guard let venueEventID else { return }
            FGInteractionHaptics.selection()
            presentFanUpdatesSheet(venueEventID: venueEventID, title: chatTitle)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.caption.weight(.bold))
                Text("Chat")
                    .font(FGTypography.metadata.weight(.heavy))
                    .lineLimit(1)
            }
            .foregroundStyle(FGColor.accentBlue)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background {
                Capsule(style: .continuous)
                    .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.18 : 0.10))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.30 : 0.22), lineWidth: 1)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.62 : 1)
        .accessibilityLabel(chatTitle)
    }

    private func venuePreviewGoingFooterButton(
        bar: BarVenue,
        event: SportsEvent,
        venueEventID: UUID?,
        alreadyInterested: Bool
    ) -> some View {
        let isPending = venueEventID.map { viewModel.isVenueEventInterestMutationInFlight($0) } ?? false
        let isDisabled = venueEventID == nil || isPending
        let fill = alreadyInterested
            ? Color(red: 0.00, green: 0.62, blue: 0.27)
            : FGColor.accentGreen.opacity(colorScheme == .dark ? 0.18 : 0.12)
        let foreground = alreadyInterested ? Color.white : FGColor.accentGreen

        return Button {
            guard venueEventID != nil else { return }
            FGInteractionHaptics.softImpact()
            viewModel.toggleVenueGameGoingFromUI(
                bar: bar,
                gameTitle: event.title,
                eventDate: event.date,
                knownVenueEventID: venueEventID,
                source: "discoverVenueGameCardFooter",
                onRequiresLogin: {
                    viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
                },
                onBusinessBlocked: {
                    viewModel.logBusinessUserGateBlocked(action: "markGoing")
                    fanFeatureGateAlertMessage = BusinessFanGateCopy.actionTapBlocked
                }
            )
        } label: {
            HStack(spacing: 5) {
                if isPending {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(foreground)
                } else {
                    Image(systemName: alreadyInterested ? "checkmark" : "plus")
                        .font(.caption.weight(.black))
                }
                Text(alreadyInterested ? "Going" : "Going?")
                    .font(FGTypography.metadata.weight(.heavy))
                    .lineLimit(1)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background {
                Capsule(style: .continuous)
                    .fill(fill)
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(FGColor.accentGreen.opacity(alreadyInterested ? 0.42 : 0.28), lineWidth: 1.2)
            }
            .shadow(color: alreadyInterested ? FGColor.accentGreen.opacity(colorScheme == .dark ? 0.30 : 0.18) : .clear, radius: 6, y: 2)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.68 : 1)
        .accessibilityLabel(alreadyInterested ? "Going" : "Mark as going")
    }

    private func venuePreviewGoingCountText(_ count: Int) -> String {
        let safeCount = max(0, count)
        return safeCount == 1 ? "1 going" : "\(safeCount) going"
    }

    private func venuePreviewCompactTeamOrb(display: VenuePreviewTeamOrbDisplayModel) -> some View {
        return ZStack {
            Circle()
                .fill(Color.black.opacity(0.35))

            if let safeFlag = display.safeFlag {
                Text(safeFlag)
                    .font(.system(size: 30))
            } else {
                Text(display.fallbackText)
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 58, height: 58)
        .accessibilityHidden(true)
    }

    private func venuePreviewGameDetail(bar: BarVenue, event: SportsEvent) -> some View {
        let gameTitle = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let venueEventID = viewModel.peekVenueEventIDForRender(for: bar, gameTitle: gameTitle)
        let predictionVisibility = venuePredictionVisibility(
            bar: bar,
            event: event,
            venueEventID: venueEventID
        )

        return VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.88)) {
                    venuePreviewDetailEvent = nil
                    if viewModel.selectedEvent?.id == event.id {
                        viewModel.clearSelectedEvent()
                    }
                }
            } label: {
                Label("Back to games", systemImage: "chevron.left")
                    .font(FGTypography.caption.weight(.bold))
                    .foregroundStyle(FGColor.accentBlue)
            }
            .buttonStyle(.plain)

            venuePreviewHeroGameCard(bar: bar, event: event, showsAttendanceFooter: false)
                .onAppear {
#if DEBUG
                    print("[GoingCrashGuard] detailGoingDisabled=true eventId=\(venueEventID?.uuidString.lowercased() ?? "nil")")
#endif
                }

            venuePreviewGameDetailPredictionCard(
                visibility: predictionVisibility
            )

        }
    }

    @ViewBuilder
    private func venuePreviewGameDetailPredictionCard(
        visibility: DiscoverVenuePredictionVisibility
    ) -> some View {
        if let eventID = visibility.eventID,
           let teams = visibility.teams,
           venuePredictionSportIsSupported(visibility.sportType) {
            VenueEventPredictionModule(
                venueEventID: eventID,
                teams: teams,
                sportType: visibility.sportType,
                summary: viewModel.venueEventPredictionSummaries[eventID],
                isLocked: visibility.isLocked,
                lockTime: visibility.lockTime,
                userPredictionReloadKey: viewModel.currentUserAuthId?.uuidString.lowercased(),
                onOpen: { type in
                    openDiscoverPredictionSheet(
                        eventID: eventID,
                        teams: teams,
                        type: type,
                        isLocked: visibility.isLocked
                    )
                },
                onQuickVote: { type, value in
                    await quickSaveDiscoverPrediction(
                        eventID: eventID,
                        type: type,
                        value: value,
                        isLocked: visibility.isLocked
                    )
                },
                onQuickScoreSave: { homeScore, awayScore in
                    await quickSaveDiscoverScorePrediction(
                        eventID: eventID,
                        homeScore: homeScore,
                        awayScore: awayScore,
                        isLocked: visibility.isLocked
                    )
                },
                onQuickScoreClear: {
                    await quickClearDiscoverScorePrediction(
                        eventID: eventID,
                        isLocked: visibility.isLocked
                    )
                },
                onRefreshSummary: {
                    await viewModel.refreshVenueEventPredictionSummary(eventID: eventID)
                },
                onLockedTap: {
                    fanFeatureGateAlertMessage = "Voting closed"
                }
            )
        }
    }

    private func venuePreviewFanChatMatchupTitle(bar: BarVenue, event: SportsEvent) -> String {
        let matchup = venuePreviewSafeMatchup(bar: bar, event: event)
        if matchup.hasResolvedTeams {
            return "\(matchup.home) vs \(matchup.away)"
        }
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Game" : title
    }

    private func venuePreviewHeroTeamTitle(_ title: String, theme: TeamTheme) -> some View {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = trimmedTitle.isEmpty ? "TEAM" : trimmedTitle
        let titleLength = displayTitle.count
        let fontSize: CGFloat = titleLength > 24 ? 27 : (titleLength > 16 ? 31 : 36)

        return Text(displayTitle)
            .font(.system(size: fontSize, weight: .black, design: .rounded))
            .tracking(titleLength > 18 ? 0.35 : 0.7)
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .minimumScaleFactor(0.55)
            .allowsTightening(true)
            .foregroundStyle(ThemeGradientBuilder.textGradient(for: theme))
            .shadow(color: theme.accent.opacity(0.42), radius: 10, y: 3)
            .shadow(color: .black.opacity(0.45), radius: 5, y: 3)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func venuePreviewCompactTitleText(
        matchup: VenuePreviewMatchup,
        eventTitle: String,
        homeTheme: TeamTheme,
        awayTheme: TeamTheme
    ) -> some View {
        let title = eventTitle.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let text: Text
        if matchup.hasResolvedTeams {
            var home = AttributedString(homeTheme.uppercaseTitle)
            home.foregroundColor = homeTheme.textColorHint ?? homeTheme.accentColor
            var separator = AttributedString(" vs ")
            separator.foregroundColor = .white.opacity(0.88)
            var away = AttributedString(awayTheme.uppercaseTitle)
            away.foregroundColor = awayTheme.textColorHint ?? awayTheme.accentColor
            home.append(separator)
            home.append(away)
            text = Text(home)
        } else {
            text = Text(title.isEmpty ? "GAME" : title).foregroundColor(.white)
        }

        return text
            .font(.system(size: 24, weight: .black, design: .rounded))
            .tracking(0.3)
            .shadow(color: .black.opacity(0.36), radius: 8, y: 3)
            .shadow(color: .black.opacity(0.44), radius: 5, y: 3)
            .lineLimit(2)
            .minimumScaleFactor(0.68)
    }

    private func venuePreviewSportDisplayModel(sport: String, league: String) -> VenuePreviewSportDisplayModel {
        let safeSport = sport.trimmingCharacters(in: .whitespacesAndNewlines)
        let displaySport = safeSport.isEmpty ? "SPORT" : safeSport
        let displayLeague = league.trimmingCharacters(in: .whitespacesAndNewlines)
        let iconName = viewModel.iconForSport(displaySport)
        let color = viewModel.colorForSport(displaySport)
        let isFallback = SportFilterCatalog.isFallbackSport(displaySport)

        return VenuePreviewSportDisplayModel(
            displaySport: displaySport,
            displayLeague: displayLeague,
            badgeLabel: venuePreviewSportLeagueLabel(sport: displaySport, league: displayLeague),
            iconName: iconName,
            color: color,
            isFallback: isFallback
        )
    }

    private func venuePreviewSportBadge(_ display: VenuePreviewSportDisplayModel, compact: Bool = false) -> some View {
        let safeIcon = safeVenuePreviewSportIcon(display.iconName)
        let safeLabel = display.badgeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = safeLabel.isEmpty ? "SPORT" : safeLabel
#if DEBUG
        print("[VenuePreviewBadgeDebug] rawIcon=\(display.iconName) safeIcon=\(safeIcon) sport=\(display.displaySport)")
#endif
        return HStack(spacing: 5) {
            Image(systemName: safeIcon)
                .font(.system(size: compact ? 9 : 11, weight: .bold, design: .rounded))
            Text(label)
                .font(.system(size: compact ? 9 : 11, weight: .black, design: .rounded))
                .textCase(.uppercase)
                .lineLimit(1)
        }
        .foregroundStyle(compact ? FGColor.accentBlue : .white.opacity(0.92))
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 5 : 7)
        .background(compact ? FGColor.accentBlue.opacity(colorScheme == .dark ? 0.16 : 0.10) : Color.white.opacity(0.16))
        .clipShape(Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(compact ? FGColor.accentBlue.opacity(0.18) : Color.white.opacity(0.15), lineWidth: 1)
        }
    }

    private func safeVenuePreviewSportIcon(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed: Set<String> = [
            "sportscourt.fill",
            "soccerball",
            "basketball.fill",
            "football.fill",
            "baseball.fill",
            "hockey.puck.fill",
            "tennisball.fill",
            "figure.run",
            "flag.checkered",
            "trophy.fill"
        ]
        return allowed.contains(trimmed) ? trimmed : "sportscourt.fill"
    }

    private func venuePreviewTeamOrb(display: VenuePreviewTeamOrbDisplayModel, sport: String) -> some View {
        let orbFill = display.usesFallbackTheme ? FGColor.accentGreen.opacity(0.28) : Color.black.opacity(0.35)

        return ZStack {
            Circle()
                .fill(orbFill)

            if let safeFlag = display.safeFlag {
                Text(safeFlag)
                    .font(.system(size: 34))
            } else {
                Text(display.fallbackText)
                    .font(.system(size: 21, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 74, height: 74)
        .accessibilityHidden(true)
        .onAppear {
            if display.safeFlag == nil, display.fallbackText == "FG" {
                logDiscoverPreviewCrashGuard(reason: "fallbackTeamText", sport: sport, team: display.rawName)
            }
            if display.safeFlag == nil, !display.rawName.isEmpty, display.fallbackText != "FG" {
                logDiscoverPreviewCrashGuard(reason: "flagFallbackInitials", sport: sport, team: display.rawName)
            }
        }
    }

    private func venuePreviewTeamOrbDisplayModel(theme: TeamTheme) -> VenuePreviewTeamOrbDisplayModel {
        let fallbackText = TeamTheme.safeFallbackText(
            rawName: theme.rawName,
            displayName: theme.displayName,
            shortName: theme.shortName
        )
        return VenuePreviewTeamOrbDisplayModel(
            rawName: theme.rawName.trimmingCharacters(in: .whitespacesAndNewlines),
            displayName: theme.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            safeFlag: TeamTheme.safeFlag(theme.flag),
            fallbackText: fallbackText.isEmpty ? "FG" : fallbackText,
            usesFallbackTheme: theme.usesFallback
        )
    }

    private func logDiscoverPreviewCrashGuard(reason: String, sport: String, team: String) {
#if DEBUG
        print("[DiscoverPreviewCrashGuard] reason=\(reason) sport=\(sport.trimmingCharacters(in: .whitespacesAndNewlines)) team=\(team.trimmingCharacters(in: .whitespacesAndNewlines))")
#endif
    }

    private func venuePreviewAttendancePresentation(
        bar: BarVenue,
        event: SportsEvent,
        venueEventID: UUID?
    ) -> (
        venueEventID: UUID?,
        alreadyInterested: Bool,
        avatarProfiles: [UserProfileRow],
        goingCount: Int
    ) {
        let gameTitle = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cardState = venueEventID.map { eventID in
            viewModel.venueGameCardState(
                input: VenueGameCardInput(
                    venueEventID: eventID,
                    barID: bar.id,
                    title: gameTitle,
                    date: event.date,
                    sport: event.sport,
                    eventTime: event.time,
                    homeTeam: nil,
                    awayTeam: nil,
                    scheduledStartAt: nil
                ),
                friendUserIDs: acceptedFriendUserIDs
            )
        }
        let alreadyInterested = viewModel.userIsGoingToVenueGame(
            bar: bar,
            gameTitle: gameTitle,
            venueEventID: venueEventID
        )
        let localAvatarProfiles = viewModel.goingAvatarProfiles(
            for: venueEventID,
            fallbackProfiles: cardState?.goingAvatarProfiles ?? [],
            currentUserGoing: alreadyInterested
        )
        let visibleAvatarCount = localAvatarProfiles
            .filter { $0.isFanVisibleForLivePresence(to: viewModel.currentUserAuthId) }
            .count
        let localInterestCount = venueEventID.map { eventID in
            max(
                viewModel.venueEventInterestCounts[eventID] ?? 0,
                viewModel.followingTabGoingInterestCounts[eventID] ?? 0
            )
        } ?? 0
        let hasLocalCount = venueEventID.map { eventID in
            viewModel.venueEventInterestCounts[eventID] != nil
                || viewModel.followingTabGoingInterestCounts[eventID] != nil
                || viewModel.isVenueEventInterestMutationInFlight(eventID)
                || viewModel.isRecentlyConfirmedVenueEventGoing(eventID)
                || viewModel.isRecentlyConfirmedVenueEventNotGoing(eventID)
        } ?? false
        let snapshotCount = cardState?.goingCount ?? 0
        let baseCount = hasLocalCount ? localInterestCount : snapshotCount
        let goingCount = max(baseCount, visibleAvatarCount, alreadyInterested ? 1 : 0)

        return (venueEventID, alreadyInterested, localAvatarProfiles, goingCount)
    }

    private func venuePreviewGamePresentation(
        bar: BarVenue,
        event: SportsEvent
    ) -> (
        venueEventID: UUID?,
        predictionVisibility: DiscoverVenuePredictionVisibility,
        cardState: VenueGameCardState?,
        alreadyInterested: Bool,
        avatarProfiles: [UserProfileRow],
        goingCount: Int,
        goingText: String
    ) {
        let gameTitle = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let venueEventID = viewModel.peekVenueEventIDForRender(for: bar, gameTitle: gameTitle)
        let predictionVisibility = venuePredictionVisibility(
            bar: bar,
            event: event,
            venueEventID: venueEventID
        )
        let cardState = venueEventID.map { eventID in
            viewModel.venueGameCardState(
                input: VenueGameCardInput(
                    venueEventID: eventID,
                    barID: bar.id,
                    title: gameTitle,
                    date: event.date,
                    sport: event.sport,
                    eventTime: event.time,
                    homeTeam: predictionVisibility.teams?.home,
                    awayTeam: predictionVisibility.teams?.away,
                    scheduledStartAt: nil
                ),
                friendUserIDs: acceptedFriendUserIDs
            )
        }
        let alreadyInterested = cardState?.isCurrentUserGoing ?? viewModel.userIsGoingToVenueGame(
            bar: bar,
            gameTitle: gameTitle,
            venueEventID: venueEventID
        )
        let energy = cardState?.liveEnergy ?? viewModel.liveEnergy(for: bar, event: event, friendUserIDs: acceptedFriendUserIDs)
        let avatarProfiles = cardState?.goingAvatarProfiles ?? viewModel.goingAvatarProfiles(
            for: venueEventID,
            fallbackProfiles: energy.socialPresenceProfiles,
            currentUserGoing: alreadyInterested
        )
        let visibleAvatarCount = avatarProfiles
            .filter { $0.isFanVisibleForLivePresence(to: viewModel.currentUserAuthId) }
            .count
        let displayGoingCount = cardState?.goingCount ?? max(energy.goingCount, alreadyInterested ? 1 : 0, visibleAvatarCount)
        let goingText = alreadyInterested || displayGoingCount > 0
            ? perGameGoingLine(venueEventID: venueEventID, count: displayGoingCount)
            : L10n.t("be_first_to_go", languageCode: appLanguageRaw)
        return (venueEventID, predictionVisibility, cardState, alreadyInterested, avatarProfiles, displayGoingCount, goingText)
    }

    private func venuePreviewSafeMatchup(
        bar: BarVenue,
        event: SportsEvent
    ) -> VenuePreviewMatchup {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let row = viewModel.cachedVenueEventRow(for: bar, gameTitle: title),
           let home = trimmedNonEmpty(row.home_team),
           let away = trimmedNonEmpty(row.away_team) {
            return VenuePreviewMatchup(home: home, away: away, hasResolvedTeams: true)
        }

        if let parsed = parseMatchupTitle(title) {
            return VenuePreviewMatchup(home: parsed.home, away: parsed.away, hasResolvedTeams: true)
        }

        if title.isEmpty {
            logVenueGameCardCrashGuard(reason: "safeMatchupTitleMissing", venue: bar, event: event)
            return VenuePreviewMatchup(home: "FanGeo", away: bar.name, hasResolvedTeams: false)
        }

        return VenuePreviewMatchup(home: title, away: bar.name, hasResolvedTeams: false)
    }

    private func venuePreviewMatchup(
        bar: BarVenue,
        event: SportsEvent,
        predictionVisibility: DiscoverVenuePredictionVisibility
    ) -> VenuePreviewMatchup {
        if let teams = predictionVisibility.teams,
           !teams.home.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !teams.away.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return VenuePreviewMatchup(home: teams.home, away: teams.away, hasResolvedTeams: true)
        }

        let trimmedTitle = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            logVenueGameCardCrashGuard(reason: "eventTitleMissing", venue: bar, event: event)
            return VenuePreviewMatchup(home: "FanGeo", away: bar.name, hasResolvedTeams: false)
        }

        let parsed = parseMatchupTitle(trimmedTitle)
        if parsed == nil {
            logVenueGameCardCrashGuard(reason: "matchupParseFallback", venue: bar, event: event)
        }
        return VenuePreviewMatchup(
            home: parsed?.home ?? trimmedTitle,
            away: parsed?.away ?? bar.name,
            hasResolvedTeams: parsed != nil
        )
    }

    private func parseMatchupTitle(_ title: String) -> (home: String, away: String)? {
        let separators = [" vs. ", " vs ", " v. ", " v ", " at ", " @ "]
        for separator in separators {
            let parts = title.components(separatedBy: separator)
            guard parts.count == 2,
                  let firstPart = parts.first,
                  let secondPart = parts.dropFirst().first else { continue }
            let first = firstPart.trimmingCharacters(in: .whitespacesAndNewlines)
            let second = secondPart.trimmingCharacters(in: .whitespacesAndNewlines)
            if !first.isEmpty && !second.isEmpty {
                return (first, second)
            }
        }
        return nil
    }

    private func venuePreviewSportLeagueLabel(sport: String, league: String) -> String {
        let sportLabel = venueGameSportDisplayLabel(sport)
        let league = league.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !league.isEmpty, league.lowercased() != "venue event" else { return sportLabel }
        return "\(sportLabel) · \(league)"
    }

    private func venuePreviewGameDateTimeText(for event: SportsEvent) -> String {
        "\(event.date.formatted(date: .abbreviated, time: .omitted)) · \(viewModel.displayTime(for: event))"
    }

    private func venuePreviewMatchupDisplayTitles(
        matchup: VenuePreviewMatchup,
        eventTitle: String,
        homeTheme: TeamTheme,
        awayTheme: TeamTheme
    ) -> (home: String, away: String) {
        if matchup.hasResolvedTeams,
           let parsed = parseMatchupTitle(eventTitle.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return (
                home: parsed.home.isEmpty ? homeTheme.uppercaseTitle : parsed.home,
                away: parsed.away.isEmpty ? awayTheme.uppercaseTitle : parsed.away
            )
        }

        if matchup.hasResolvedTeams {
            return (home: homeTheme.uppercaseTitle, away: awayTheme.uppercaseTitle)
        }

        if let parsed = parseMatchupTitle(eventTitle.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return (home: parsed.home, away: parsed.away)
        }

        let fallbackTitle = eventTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            home: fallbackTitle.isEmpty ? homeTheme.uppercaseTitle : fallbackTitle,
            away: awayTheme.uppercaseTitle
        )
    }

    private func venuePreviewGameStatusTitle(
        bar: BarVenue,
        event: SportsEvent,
        venueEventID: UUID?
    ) -> String? {
        let row = venueEventID.flatMap { resolvedID in
            viewModel.venueEventRows.first(where: { $0.id == resolvedID })
        } ?? viewModel.cachedVenueEventRow(for: bar, gameTitle: event.title.trimmingCharacters(in: .whitespacesAndNewlines))

        let normalizedStatus = row?.admin_status?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        switch normalizedStatus {
        case "", "active", "confirmed":
            return nil
        case "cancelled", "canceled", "inactive", "deleted":
            return "Cancelled"
        case "postponed":
            return "Postponed"
        case "live":
            return "Live"
        case "final":
            return "Final"
        default:
            return nil
        }
    }

    private func venuePreviewGameStatusTint(_ statusTitle: String?) -> Color {
        switch statusTitle?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "cancelled", "canceled":
            return FGColor.dangerRed
        case "postponed":
            return FGColor.accentYellow
        case "live":
            return FGColor.accentGreen
        case "final":
            return FGColor.accentBlue
        default:
            return FGColor.accentGreen
        }
    }

    private func openVenuePreviewGameDetail(_ event: SportsEvent) {
        guard !viewModel.isGuestDiscoverMode else {
            showVenueDetails = true
            return
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            venuePreviewDetailEvent = event
        }
    }

    private func venuePreviewStableGameItems(
        for stableEvents: [SportsEvent],
        selectedVenueID: UUID
    ) -> [VenuePreviewStableGameItem] {
        let groupedIDs = Dictionary(grouping: stableEvents.map(\.id), by: { $0 })
        let duplicateIDs = Set(groupedIDs.compactMap { id, values in values.count > 1 ? id : nil })
        let gameIDText = stableEvents.map { $0.id.uuidString.lowercased() }.joined(separator: ",")
        let duplicateIDText = duplicateIDs.map { $0.uuidString.lowercased() }.sorted().joined(separator: ",")
#if DEBUG
        print("[VenuePreviewStabilityDebug] gameCount=\(stableEvents.count)")
        print("[VenuePreviewStabilityDebug] gameIds=\(gameIDText)")
        print("[VenuePreviewStabilityDebug] duplicateGameIds=\(duplicateIDText.isEmpty ? "none" : duplicateIDText)")
        print("[VenuePreviewStabilityDebug] selectedVenueId=\(selectedVenueID.uuidString.lowercased())")
#endif
        return stableEvents.enumerated().map { index, event in
            let uuidText = event.id.uuidString.lowercased()
            let stableID = duplicateIDs.contains(event.id) ? "\(uuidText)-\(index)" : uuidText
            return VenuePreviewStableGameItem(id: stableID, index: index, event: event)
        }
    }

    private func venuePreviewOrderedGames(bar: BarVenue, gamesToday: [SportsEvent]) -> [SportsEvent] {
        gamesToday.sorted { lhs, rhs in
            let left = venuePreviewGameOrderComponents(bar: bar, event: lhs)
            let right = venuePreviewGameOrderComponents(bar: bar, event: rhs)

            if let leftCreatedAt = left.createdAt,
               let rightCreatedAt = right.createdAt,
               leftCreatedAt != rightCreatedAt {
                return leftCreatedAt < rightCreatedAt
            }

            if left.eventID != right.eventID {
                return left.eventID < right.eventID
            }

            let titleCompare = left.title.localizedCaseInsensitiveCompare(right.title)
            if titleCompare != .orderedSame {
                return titleCompare == .orderedAscending
            }

            return left.originalID < right.originalID
        }
    }

    private func venuePreviewGameOrderComponents(
        bar: BarVenue,
        event: SportsEvent
    ) -> (createdAt: String?, eventID: String, title: String, originalID: String) {
        let row = venuePreviewOrderRow(bar: bar, event: event)
        let createdAt = trimmedNonEmpty(row?.created_at)
        let stableEventID = row?.id?.uuidString.lowercased()
            ?? viewModel.peekVenueEventIDForRender(for: bar, gameTitle: event.title.trimmingCharacters(in: .whitespacesAndNewlines))?.uuidString.lowercased()
            ?? event.id.uuidString.lowercased()
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return (createdAt, stableEventID, title, event.id.uuidString.lowercased())
    }

    private func venuePreviewOrderRow(bar: BarVenue, event: SportsEvent) -> VenueEventRow? {
        if let eventID = viewModel.peekVenueEventIDForRender(for: bar, gameTitle: event.title.trimmingCharacters(in: .whitespacesAndNewlines)),
           let row = viewModel.venueEventRows.first(where: { $0.id == eventID }) {
            return row
        }

        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let eventDay = venuePreviewOrderSQLDayString(for: event.date)
        return viewModel.venueEventRows.first { row in
            guard venueEventRowMatchesDiscoverVenue(row, bar: bar) else { return false }
            guard trimmedNonEmpty(row.event_title)?.caseInsensitiveCompare(title) == .orderedSame else { return false }
            if let rowDay = trimmedNonEmpty(row.event_date) {
                return rowDay == eventDay
            }
            return true
        }
    }

    private func venuePreviewOrderSQLDayString(for date: Date) -> String {
        DiscoverPreviewDateFormatters.sqlDay.string(from: date)
    }

    private func logVenueGameOrderDebug(events: [SportsEvent], bar: BarVenue) {
#if DEBUG
        let ids = events.map {
            venuePreviewGameOrderComponents(bar: bar, event: $0).eventID
        }.joined(separator: ",")
        print("[VenueGameOrderDebug] order=createdAt eventIds=\(ids)")
#endif
    }

    private func venuePreviewNoGamesForSelectedDayView(bar: BarVenue) -> some View {
        let selectedDayLabel = venuePreviewSelectedDayLabel(for: viewModel.selectedDate)
        let nextAvailableGame = venuePreviewNextAvailableGame(for: bar)
        let isUnclaimed = bar.isUnclaimedCommunityVenue

        return HStack(alignment: .top, spacing: FGSpacing.sm) {
            Image(systemName: isUnclaimed ? "building.2" : "calendar.badge.exclamationmark")
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                if isUnclaimed, nextAvailableGame == nil {
                    Text(L10n.t("venue_no_games_unclaimed", languageCode: appLanguageRaw))
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))

                    Text(L10n.t("venue_no_games_unclaimed_subtitle", languageCode: appLanguageRaw))
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        requestUnclaimedVenueClaim(for: bar)
                    } label: {
                        Text(L10n.t("venue_claim_this_venue", languageCode: appLanguageRaw))
                            .font(FGTypography.caption.weight(.bold))
                            .foregroundStyle(FGColor.accentBlue)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                } else {
                    Text(String(format: L10n.t("no_games_listed_for_format", languageCode: appLanguageRaw), selectedDayLabel))
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))

                    if let nextAvailableGame {
                        Text(String(format: L10n.t("next_available_game_format", languageCode: appLanguageRaw), nextAvailableGame.title, nextAvailableGame.dateText, nextAvailableGame.timeText))
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(L10n.t("check_back_soon", languageCode: appLanguageRaw))
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                }
            }
        }
        .padding(FGSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(discoverPreviewInnerSurface)
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                .strokeBorder(discoverPreviewControlBorder.opacity(colorScheme == .dark ? 0.9 : 0.7), lineWidth: 1)
        }
        .onAppear {
#if DEBUG
            print("[VenueCardEmptyStateDebug] selectedDay=\(selectedDayLabel)")
            print("[VenueCardEmptyStateDebug] noGamesForSelectedDay=true")
            if let nextAvailableGame {
                print("[VenueCardEmptyStateDebug] nextAvailableGame=\(nextAvailableGame.title) · \(nextAvailableGame.dateText) · \(nextAvailableGame.timeText)")
            } else {
                print("[VenueCardEmptyStateDebug] nextAvailableGame=none")
            }
#endif
        }
    }

    private func venuePreviewSelectedDayLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        }
        if calendar.isDateInTomorrow(date) {
            return "Tomorrow"
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func venuePreviewDateLabel(for date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func venuePreviewTimeLabel(for date: Date, fallback: String?) -> String {
        let fallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fallback.isEmpty, fallback.lowercased() != "time tbd" {
            return CompactGameTimeFormatter.timeWithZone(
                rawTime: fallback,
                timeZoneOption: viewModel.selectedTimeZone
            )
        }
        return CompactGameTimeFormatter.timeWithZone(
            for: date,
            timeZoneOption: viewModel.selectedTimeZone
        )
    }

    private func venuePreviewNextAvailableGame(for bar: BarVenue) -> (title: String, dateText: String, timeText: String)? {
        let calendar = Calendar.current
        let selectedDayStart = calendar.startOfDay(for: viewModel.selectedDate)
        let earliestFutureDay = calendar.date(byAdding: .day, value: 1, to: selectedDayStart) ?? selectedDayStart
        let barName = bar.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sportFilter = viewModel.selectedSport

        let candidates = viewModel.venueEventRows.compactMap { row -> (title: String, start: Date, timeText: String)? in
            let status = row.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "active"
            guard status == "active" else { return nil }
            guard VenueGameExpiration.isActiveOnDiscoverSurfaces(row: row) else { return nil }
            if sportFilter != "All" {
                let rowSport = row.sport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard rowSport == sportFilter else { return nil }
            }

            let matchesVenue: Bool
            if let venueID = row.venue_id {
                matchesVenue = venueID == bar.id
            } else {
                let venueName = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                matchesVenue = !venueName.isEmpty && venueName.caseInsensitiveCompare(barName) == .orderedSame
            }
            guard matchesVenue else { return nil }

            guard let start = VenueGameExpiration.scheduledStartDate(for: row),
                  start >= earliestFutureDay else { return nil }
            let title = row.event_title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return nil }
            return (title, start, venuePreviewTimeLabel(for: start, fallback: row.event_time))
        }
        .sorted { $0.start < $1.start }

        if let next = candidates.first {
            return (
                title: next.title,
                dateText: venuePreviewDateLabel(for: next.start),
                timeText: next.timeText
            )
        }

        let eventCandidates = viewModel.events
            .filter { event in
                event.league == "Venue Event"
                    && event.date >= earliestFutureDay
                    && (sportFilter == "All" || event.sport == sportFilter)
                    && bar.games.contains(event.title)
            }
            .sorted { $0.date < $1.date }

        guard let next = eventCandidates.first else { return nil }
        return (
            title: next.title,
            dateText: venuePreviewDateLabel(for: next.date),
            timeText: venuePreviewTimeLabel(for: next.date, fallback: next.time)
        )
    }
    
    private func trendingScore(for venueEventID: UUID, goingCount: Int) -> Int {
        let commentCount = viewModel.fanUpdatesDisplayCommentCount(for: venueEventID)

        let vibeCount = fanUpdatesStore.venueEventVibeCounts[venueEventID]?
            .values
            .reduce(0, +) ?? 0

        return goingCount + commentCount + vibeCount
    }
    
    private func trendingLabel(for score: Int) -> String? {
        if score >= 40 {
            return "👑 Trending now"
        } else if score >= 16 {
            return "🚀 Hot"
        } else if score >= 6 {
            return "🔥 Active"
        } else if score >= 1 {
            return "✨ Starting up"
        }

        return nil
    }
    
    private func perGameGoingLine(venueEventID: UUID?, count: Int) -> String {
        guard let venueEventID else {
            return count > 0
                ? String(format: L10n.t("going_count_format", languageCode: appLanguageRaw), "\(count)")
                : L10n.t("be_first_to_go", languageCode: appLanguageRaw)
        }
        let im = viewModel.isInterestedInVenueEvent(venueEventID)
        if count <= 0 { return im ? L10n.t("im_going", languageCode: appLanguageRaw) : L10n.t("be_first_to_go", languageCode: appLanguageRaw) }
        if im {
            return count == 1
                ? L10n.t("im_going", languageCode: appLanguageRaw)
                : String(format: L10n.t("going_count_format", languageCode: appLanguageRaw), "\(count)")
        }
        return String(format: L10n.t("going_count_format", languageCode: appLanguageRaw), "\(count)")
    }

    private func logVenuePreviewModeDebug(renderingFullGameCard: Bool, eventTitle: String) {
#if DEBUG
        guard VenueGameCardDiagnostics.enabled else { return }
        print("[VenuePreviewModeDebug] isGuestDiscoverMode=\(viewModel.isGuestDiscoverMode)")
        print("[VenuePreviewModeDebug] isLoggedIn=\(viewModel.isAuthenticatedForSocialFeatures)")
        print("[VenuePreviewModeDebug] renderingFullGameCard=\(renderingFullGameCard)")
        print("[VenuePreviewModeDebug] renderingGuestPreviewRow=\(!renderingFullGameCard)")
        print("[VenuePreviewModeDebug] eventTitle=\(eventTitle)")
#endif
    }

    private func logGoingAvatarDebug(
        currentUserGoing: Bool,
        avatarStackCount: Int,
        emptyGoingPromptVisible: Bool
    ) {
#if DEBUG
        guard VenueGameCardDiagnostics.enabled else { return }
        print("[GoingAvatarDebug] currentUserGoing=\(currentUserGoing)")
        print("[GoingAvatarDebug] avatarStackCount=\(avatarStackCount)")
        print("[GoingAvatarDebug] emptyGoingPromptVisible=\(emptyGoingPromptVisible)")
#endif
    }

    private func logVenueGameCardStoreRender(state: VenueGameCardState?) {
#if DEBUG
        guard VenueGameCardDiagnostics.enabled else { return }
        guard let state else { return }
        print("[VenueGameCardStoreDebug] phase=renderFromMirror")
        print("[VenueGameCardStoreDebug] render eventId=\(state.input.venueEventID.uuidString.lowercased())")
        print("[VenueGameCardStoreDebug] renderUsingMirror=true")
#endif
    }

    @ViewBuilder
    private func liveEnergyChips(_ energy: FanGeoLiveEnergy) -> some View {
        if energy.compactChips.isEmpty {
            Text(energy.goingCount > 0 ? "\(energy.goingCount) fans going" : "Start the crowd")
                .font(FGTypography.metadata)
                .fontWeight(.semibold)
                .foregroundStyle(energy.goingCount > 0 ? FGColor.accentGreen : discoverPreviewSecondaryTextColor)
        } else {
            FGWrappingLayout(horizontalSpacing: FGSpacing.xs, verticalSpacing: FGSpacing.xs) {
                ForEach(energy.compactChips, id: \.self) { chip in
                    liveEnergyChip(chip)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func liveEnergyChip(_ chip: String) -> some View {
        let tint = liveEnergyChipTint(chip)

        return Text(chip)
            .font(FGTypography.metadata.weight(.bold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                Capsule(style: .continuous)
                    .fill(tint.opacity(colorScheme == .dark ? 0.18 : 0.12))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(0.28), lineWidth: 1)
            }
    }

    private func liveEnergyChipTint(_ chip: String) -> Color {
        if chip.contains("LIVE NOW") { return FGColor.dangerRed }
        if chip.contains("Crowd building") { return FGColor.accentYellow }
        return FGColor.accentBlue
    }

    private func guestVenueGamePreviewRow(bar: BarVenue, event: SportsEvent, onOpenLockedDetail: @escaping () -> Void) -> some View {
        let matchup = venuePreviewSafeMatchup(bar: bar, event: event)
        let homeTheme = TeamTheme.resolve(matchup.home)
        let awayTheme = TeamTheme.resolve(matchup.away)
        let eventID = event.id.uuidString.lowercased()
        let sportDisplay = venuePreviewSportDisplayModel(sport: event.sport, league: event.league)
        let displayTitles = venuePreviewMatchupDisplayTitles(
            matchup: matchup,
            eventTitle: event.title,
            homeTheme: homeTheme,
            awayTheme: awayTheme
        )

        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                viewModel.selectedEvent = event
                onOpenLockedDetail()
            }
        } label: {
            VenueMatchupCardView(
                homeTheme: homeTheme,
                awayTheme: awayTheme,
                homeTitle: displayTitles.home,
                awayTitle: displayTitles.away,
                sportLabel: sportDisplay.badgeLabel,
                sportIconName: sportDisplay.iconName,
                dateTimeText: venuePreviewGameDateTimeText(for: event),
                statusTitle: "Sign in",
                statusTint: FGColor.accentBlue,
                eventId: eventID,
                cardVariant: "guestPreview",
                height: 166,
                cornerRadius: 22
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.10), radius: 12, x: 0, y: 7)
        }
        .buttonStyle(.plain)
        .onAppear {
#if DEBUG
            print("[VenueGameCardUI] appliedElevatedCardStyle=true")
            print("[HeroCardLayoutDebug] variant=guestPreview eventId=\(eventID)")
#endif
        }
    }

    private func venueGameSportIconWithLabel(sport: String) -> some View {
        let label = venueGameSportDisplayLabel(sport)
        let tint = viewModel.colorForSport(sport)

        return VStack(spacing: 3) {
            SportArtworkIconView(sport: sport, diameter: 42)

            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 54, alignment: .top)
        .onAppear {
#if DEBUG
            print("[VenueGameCardDebug] sportLabelRendered=\(label)")
            print("[VenueGameCardDebug] sportIconAndLabelVisible=true")
#endif
        }
    }

    private func venueGameSportDisplayLabel(_ sport: String) -> String {
        let trimmed = sport.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed.lowercased()
        switch key {
        case "nba", "basketball":
            return "Basketball"
        case "mls", "premier league", "soccer":
            return "Soccer"
        case "nfl", "football", "american football":
            return "Football"
        case "mlb", "baseball":
            return "Baseball"
        case "nhl", "hockey", "ice hockey":
            return "Hockey"
        case "ufc", "mma", "combat sports":
            return "MMA"
        case "tennis":
            return "Tennis"
        case "badminton", "shuttlecock":
            return "Badminton"
        case "formula 1", "formula1", "formula one", "f1", "racing":
            return "Formula 1"
        default:
            return trimmed.isEmpty ? "Sports" : trimmed
        }
    }

    private func gameInterestRow(bar: BarVenue, event: SportsEvent) -> some View {
        VenueGameCardSnapshotObservedContent(store: viewModel.venueGameCardSnapshotStore) {
            gameInterestRowContent(bar: bar, event: event)
        }
    }

    private func gameInterestRowContent(bar: BarVenue, event: SportsEvent) -> some View {
        let gameTitle = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let venueEventID = viewModel.peekVenueEventIDForRender(for: bar, gameTitle: gameTitle)

        let predictionVisibility = venuePredictionVisibility(
            bar: bar,
            event: event,
            venueEventID: venueEventID
        )
        let cardState = venueEventID.map { eventID in
            viewModel.venueGameCardState(
                input: VenueGameCardInput(
                    venueEventID: eventID,
                    barID: bar.id,
                    title: gameTitle,
                    date: event.date,
                    sport: event.sport,
                    eventTime: event.time,
                    homeTeam: predictionVisibility.teams?.home,
                    awayTeam: predictionVisibility.teams?.away,
                    scheduledStartAt: nil
                ),
                friendUserIDs: acceptedFriendUserIDs
            )
        }
        let alreadyInterested = cardState?.isCurrentUserGoing ?? viewModel.userIsGoingToVenueGame(
            bar: bar,
            gameTitle: gameTitle,
            venueEventID: venueEventID
        )
        let energy = cardState?.liveEnergy ?? viewModel.liveEnergy(for: bar, event: event, friendUserIDs: acceptedFriendUserIDs)
        let previewEnergy = venueEventID.map { eventID in
            if let cardState {
                venuePreviewEnergy(
                    for: eventID,
                    energy: cardState.liveEnergy,
                    counts: cardState.miniStats.vibeCounts
                )
            } else {
                venuePreviewEnergy(for: eventID, energy: energy)
            }
        }
        let previewEnergyPalette = venueGamePreviewEnergyPalette(previewEnergy)
        let previewEnergyTint = previewEnergy.map { energyAccentColor(for: $0.score) } ?? FGColor.accentBlue
        let previewEnergyBorder = previewEnergy?.isHighEnergy == true
            ? previewEnergyTint.opacity(colorScheme == .dark ? 0.58 : 0.42)
            : discoverPreviewControlBorder
        let previewEnergyGlow = previewEnergy?.isHighEnergy == true
            ? previewEnergyTint.opacity(colorScheme == .dark ? 0.22 : 0.14)
            : Color.clear
        let matchup = venuePreviewMatchup(
            bar: bar,
            event: event,
            predictionVisibility: predictionVisibility
        )
        let homeTheme = TeamTheme.resolve(matchup.home)
        let awayTheme = TeamTheme.resolve(matchup.away)
        let eventID = venueEventID?.uuidString.lowercased() ?? event.id.uuidString.lowercased()
        let sportDisplay = venuePreviewSportDisplayModel(sport: event.sport, league: event.league)
        let displayTitles = venuePreviewMatchupDisplayTitles(
            matchup: matchup,
            eventTitle: event.title,
            homeTheme: homeTheme,
            awayTheme: awayTheme
        )
        let statusTitle = venuePreviewGameStatusTitle(bar: bar, event: event, venueEventID: venueEventID)
        let avatarProfiles = cardState?.goingAvatarProfiles ?? viewModel.goingAvatarProfiles(
            for: venueEventID,
            fallbackProfiles: energy.socialPresenceProfiles,
            currentUserGoing: alreadyInterested
        )
        let visibleAvatarCount = avatarProfiles
            .filter { $0.isFanVisibleForLivePresence(to: viewModel.currentUserAuthId) }
            .count
        let displayGoingCount = cardState?.goingCount ?? max(energy.goingCount, alreadyInterested ? 1 : 0, visibleAvatarCount)
        let emptyGoingPromptVisible = displayGoingCount == 0 && !alreadyInterested
        let _ = logGoingAvatarDebug(
            currentUserGoing: alreadyInterested,
            avatarStackCount: visibleAvatarCount,
            emptyGoingPromptVisible: emptyGoingPromptVisible
        )
#if DEBUG
        let _ = logVenueGameCardStoreRender(state: cardState)
#endif

        return VStack(alignment: .leading, spacing: 13) {
            VenueMatchupCardView(
                homeTheme: homeTheme,
                awayTheme: awayTheme,
                homeTitle: displayTitles.home,
                awayTitle: displayTitles.away,
                sportLabel: sportDisplay.badgeLabel,
                sportIconName: sportDisplay.iconName,
                dateTimeText: venuePreviewGameDateTimeText(for: event),
                statusTitle: statusTitle,
                statusTint: venuePreviewGameStatusTint(statusTitle),
                eventId: eventID,
                cardVariant: "interestRow",
                height: 166,
                cornerRadius: 22
            )

            venuePreviewGameSocialFooter(
                bar: bar,
                event: event,
                venueEventID: venueEventID,
                chatTitle: venuePreviewFanChatMatchupTitle(bar: bar, event: event),
                alreadyInterested: alreadyInterested,
                avatarProfiles: avatarProfiles,
                goingCount: displayGoingCount,
                avatarDiameter: 26,
                textFont: FGTypography.caption.weight(.semibold)
            )
            .padding(.horizontal, -8)
            .padding(.top, -6)

            if let venueEventID {
                Divider()
                    .overlay(discoverPreviewControlBorder.opacity(colorScheme == .dark ? 0.72 : 0.46))
                    .padding(.vertical, 1)
                if let miniStats = cardState?.miniStats {
                    venuePreviewInteractionStrip(venueEventID: venueEventID, miniStats: miniStats)
                } else {
                    venuePreviewInteractionStrip(venueEventID: venueEventID)
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 13)
        .background(
            venueGameElevatedCardBackground(
                border: previewEnergyBorder,
                accent: previewEnergyTint,
                homeTheme: homeTheme,
                awayTheme: awayTheme,
                eventId: eventID,
                cardVariant: "interestRow"
            )
        )
        .overlay(alignment: .top) {
            if previewEnergy?.hasBadge == true {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: previewEnergyPalette.topEdgeColors,
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 2)
                    .padding(.horizontal, 28)
                    .padding(.top, 1)
            }
        }
        .shadow(color: previewEnergyGlow, radius: 10, x: 0, y: 3)
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.30 : 0.11), radius: 14, x: 0, y: 8)
        .onAppear {
#if DEBUG
            print("[VenueGameCardUI] appliedElevatedCardStyle=true")
            print("[HeroCardLayoutDebug] variant=interestRow eventId=\(eventID)")
#endif
        }
    }

    private func venueGameElevatedCardBackground(
        border: Color,
        accent: Color,
        homeTheme: TeamTheme,
        awayTheme: TeamTheme,
        eventId: String,
        cardVariant: String
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(FGColor.cardBackground(colorScheme))
            safeVenueGameGradient(
                homeTheme: homeTheme,
                awayTheme: awayTheme,
                eventId: eventId,
                cardVariant: cardVariant
            )
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(venueGameElevatedSurface.opacity(colorScheme == .dark ? 0.78 : 0.72))
        }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                accent.opacity(colorScheme == .dark ? 0.10 : 0.055),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                border.opacity(colorScheme == .dark ? 0.95 : 0.76),
                                accent.opacity(colorScheme == .dark ? 0.22 : 0.16),
                                Color.white.opacity(colorScheme == .dark ? 0.06 : 0.82)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
    }

    private func venueGamePredictionInset<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(venueGamePredictionInsetSurface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.24 : 0.16), lineWidth: 1)
        }
        .onAppear {
#if DEBUG
            print("[VenueGameCardUI] predictionInsetStyle=true")
#endif
        }
    }

    private func openDiscoverPredictionSheet(
        eventID: UUID,
        teams: VenueEventPredictionTeams,
        type: VenueEventPredictionType,
        isLocked: Bool
    ) {
        guard type != .score else { return }
        if let unavailableMessage = venuePredictionUnavailableMessage(eventID: eventID, isLocked: isLocked) {
            fanFeatureGateAlertMessage = unavailableMessage
            return
        }
        guard !isLocked else {
            fanFeatureGateAlertMessage = "Voting closed"
            return
        }
        guard viewModel.isAuthenticatedForSocialFeatures else {
            viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
            return
        }
        guard viewModel.canUseFanSocialFeatures else {
            viewModel.logBusinessUserGateBlocked(action: "venuePrediction")
            fanFeatureGateAlertMessage = BusinessFanGateCopy.actionTapBlocked
            return
        }
#if DEBUG
        print("[PredictionDebug] open eventId=\(eventID.uuidString.lowercased())")
#endif
        predictionSheet = DiscoverPredictionSheetContext(
            venueEventID: eventID,
            teams: teams,
            predictionType: type,
            unavailableMessage: venuePredictionUnavailableMessage(eventID: eventID, isLocked: isLocked),
            lockTime: predictionLockTimeForDiscoverEvent(eventID)
        )
    }

    private func predictionLockTimeForDiscoverEvent(_ eventID: UUID) -> Date? {
        guard let row = viewModel.venueEventRows.first(where: { $0.id == eventID }) else { return nil }
        return venuePredictionStartDate(for: row)?.addingTimeInterval(10 * 60)
    }

    @MainActor
    private func quickSaveDiscoverScorePrediction(
        eventID: UUID,
        homeScore: Int,
        awayScore: Int,
        isLocked: Bool
    ) async -> Bool {
        if let unavailableMessage = venuePredictionUnavailableMessage(eventID: eventID, isLocked: isLocked) {
            fanFeatureGateAlertMessage = unavailableMessage
            return false
        }
        guard !isLocked else {
            fanFeatureGateAlertMessage = "Voting closed"
            return false
        }
        guard viewModel.isAuthenticatedForSocialFeatures else {
            viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
            return false
        }
        guard viewModel.canUseFanSocialFeatures else {
            viewModel.logBusinessUserGateBlocked(action: "venuePrediction")
            fanFeatureGateAlertMessage = BusinessFanGateCopy.actionTapBlocked
            return false
        }
        do {
#if DEBUG
            print("[PredictionVoteDebug] submit eventId=\(eventID.uuidString.lowercased()) choice=\(homeScore)-\(awayScore)")
#endif
            try await VenueEventPredictionService.shared.upsertPrediction(
                venueEventId: eventID,
                predictionType: .score,
                predictedHomeScore: homeScore,
                predictedAwayScore: awayScore
            )
            await viewModel.refreshVenueEventPredictionSummary(eventID: eventID)
            return true
        } catch {
            let message = VenueEventPredictionUserMessage.message(for: error)
            fanFeatureGateAlertMessage = message
#if DEBUG
            print("[PredictionDebug] error=\(error.localizedDescription)")
            print("[PredictionVoteDebug] error=\(error.localizedDescription)")
            print("[PredictionVoteDebug] cancelled=\(VenueEventPredictionUserMessage.isCancellation(error))")
#endif
            return false
        }
    }

    @MainActor
    private func quickClearDiscoverScorePrediction(
        eventID: UUID,
        isLocked: Bool
    ) async -> Bool {
        if let unavailableMessage = venuePredictionUnavailableMessage(eventID: eventID, isLocked: isLocked) {
            fanFeatureGateAlertMessage = unavailableMessage
            return false
        }
        guard !isLocked else {
            fanFeatureGateAlertMessage = "Voting closed"
            return false
        }
        guard viewModel.isAuthenticatedForSocialFeatures else {
            viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
            return false
        }
        guard viewModel.canUseFanSocialFeatures else {
            viewModel.logBusinessUserGateBlocked(action: "venuePrediction")
            fanFeatureGateAlertMessage = BusinessFanGateCopy.actionTapBlocked
            return false
        }
        do {
            try await VenueEventPredictionService.shared.deletePrediction(
                venueEventId: eventID,
                predictionType: .score
            )
            await viewModel.refreshVenueEventPredictionSummary(eventID: eventID)
            return true
        } catch {
            let message = VenueEventPredictionUserMessage.message(for: error)
            fanFeatureGateAlertMessage = message
#if DEBUG
            print("[PredictionDebug] error=\(error.localizedDescription)")
            print("[PredictionVoteDebug] error=\(error.localizedDescription)")
            print("[PredictionVoteDebug] cancelled=\(VenueEventPredictionUserMessage.isCancellation(error))")
#endif
            return false
        }
    }

    @MainActor
    private func quickSaveDiscoverPrediction(
        eventID: UUID,
        type: VenueEventPredictionType,
        value: String,
        isLocked: Bool
    ) async -> Bool {
        if let unavailableMessage = venuePredictionUnavailableMessage(eventID: eventID, isLocked: isLocked) {
            fanFeatureGateAlertMessage = unavailableMessage
            return false
        }
        guard !isLocked else {
            fanFeatureGateAlertMessage = "Voting closed"
            return false
        }
        guard viewModel.isAuthenticatedForSocialFeatures else {
            viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
            return false
        }
        guard viewModel.canUseFanSocialFeatures else {
            viewModel.logBusinessUserGateBlocked(action: "venuePrediction")
            fanFeatureGateAlertMessage = BusinessFanGateCopy.actionTapBlocked
            return false
        }
        do {
#if DEBUG
            print("[PredictionVoteDebug] submit eventId=\(eventID.uuidString.lowercased()) choice=\(value)")
#endif
            switch type {
            case .winner:
                try await VenueEventPredictionService.shared.upsertPrediction(
                    venueEventId: eventID,
                    predictionType: .winner,
                    predictedWinner: value
                )
            case .firstScoreTeam:
                try await VenueEventPredictionService.shared.upsertPrediction(
                    venueEventId: eventID,
                    predictionType: .firstScoreTeam,
                    predictedFirstScoreTeam: value
                )
            case .score:
                return false
            }
            await viewModel.refreshVenueEventPredictionSummary(eventID: eventID)
            return true
        } catch {
            let message = VenueEventPredictionUserMessage.message(for: error)
            fanFeatureGateAlertMessage = message
#if DEBUG
            print("[PredictionDebug] error=\(error.localizedDescription)")
            print("[PredictionVoteDebug] error=\(error.localizedDescription)")
            print("[PredictionVoteDebug] cancelled=\(VenueEventPredictionUserMessage.isCancellation(error))")
#endif
            return false
        }
    }

    private func venuePredictionVisibility(
        bar: BarVenue,
        event: SportsEvent,
        venueEventID: UUID?
    ) -> DiscoverVenuePredictionVisibility {
        let row = venueEventRowForPrediction(bar: bar, event: event, venueEventID: venueEventID)
        let resolvedEventID = venueEventID ?? row?.id
        let sportType = trimmedNonEmpty(row?.sport) ?? event.sport
        let matchupFallback = venuePreviewSafeMatchup(bar: bar, event: event)
        let homeTeam = trimmedNonEmpty(row?.home_team) ?? (matchupFallback.hasResolvedTeams ? matchupFallback.home : "Home")
        let awayTeam = trimmedNonEmpty(row?.away_team) ?? (matchupFallback.hasResolvedTeams ? matchupFallback.away : "Away")
        let startsAt = row.flatMap(venuePredictionStartDate(for:)) ?? venuePredictionFallbackStartDate(for: event)
        let lockTime = startsAt?.addingTimeInterval(10 * 60)
        let isLocked = lockTime.map { Date() > $0 } ?? false
        let isCancelled = row.map { venuePredictionRowIsCancelled($0) } ?? false
        let hiddenReason: String?

        if resolvedEventID == nil {
            hiddenReason = "missingVenueEventId"
        } else if isCancelled {
            hiddenReason = "cancelled"
        } else if !venuePredictionSportIsSupported(sportType) {
            hiddenReason = "unsupportedSport"
        } else if startsAt == nil {
            hiddenReason = "missingStartTime"
        } else {
            hiddenReason = nil
        }

        let teams = VenueEventPredictionTeams(home: homeTeam, away: awayTeam)

        let visibility = DiscoverVenuePredictionVisibility(
            eventID: resolvedEventID,
            sportType: sportType,
            teams: teams,
            hasHomeTeam: true,
            hasAwayTeam: true,
            startsAt: startsAt,
            lockTime: lockTime,
            isLocked: isLocked,
            isCancelled: isCancelled,
            hiddenReason: hiddenReason
        )
        logVenuePredictionVisibility(visibility)
        return visibility
    }

    private func venuePredictionUnavailableMessage(eventID: UUID?, isLocked: Bool) -> String? {
        guard let eventID else {
            return "Couldn’t save your pick. Please try again."
        }
        if let row = viewModel.venueEventRows.first(where: { $0.id == eventID }),
           venuePredictionRowIsCancelled(row) {
            return VenueEventPredictionUserMessage.inactiveGame
        }
        if isLocked {
            return "Voting closed"
        }
        return nil
    }

    private func venuePredictionRowIsCancelled(_ row: VenueEventRow) -> Bool {
        let status = row.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "active"
        return status == "cancelled" || status == "canceled" || status == "inactive" || status == "deleted"
    }

    private func venueEventRowForPrediction(
        bar: BarVenue,
        event: SportsEvent,
        venueEventID: UUID?
    ) -> VenueEventRow? {
        if let venueEventID,
           let byID = viewModel.venueEventRows.first(where: { $0.id == venueEventID }) {
            return byID
        }

        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return viewModel.venueEventRows.first { row in
            guard venueEventRowMatchesDiscoverVenue(row, bar: bar) else { return false }
            guard trimmedNonEmpty(row.event_title)?.caseInsensitiveCompare(title) == .orderedSame else { return false }
            guard let rowStart = venuePredictionStartDate(for: row) ?? venuePredictionFallbackDay(for: row) else { return true }
            return Calendar.current.isDate(rowStart, inSameDayAs: event.date)
        }
    }

    private func venueEventRowMatchesDiscoverVenue(_ row: VenueEventRow, bar: BarVenue) -> Bool {
        if row.venue_id == bar.id { return true }
        if let venueName = trimmedNonEmpty(row.venue_name),
           venueName.caseInsensitiveCompare(bar.name) == .orderedSame {
            return true
        }
        if let rowOwner = trimmedNonEmpty(row.owner_email),
           let barOwner = bar.ownerEmail,
           OwnerBusinessEmail.normalized(rowOwner) == OwnerBusinessEmail.normalized(barOwner) {
            return true
        }
        return false
    }

    private func venuePredictionSportIsSupported(_ value: String) -> Bool {
        switch venuePredictionNormalizedSport(value) {
        case "soccer", "baseball", "football", "hockey":
            return true
        default:
            return false
        }
    }

    private func venuePredictionNormalizedSport(_ value: String) -> String {
        let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.contains("soccer") { return "soccer" }
        if lowered.contains("baseball") || lowered == "mlb" { return "baseball" }
        if lowered.contains("football") || lowered == "nfl" { return "football" }
        if lowered.contains("hockey") || lowered == "nhl" { return "hockey" }
        return lowered
    }

    private func venuePredictionStartDate(for row: VenueEventRow) -> Date? {
        if let start = FanGeoLiveEnergyTiming.parseScheduledStart(row.scheduled_start_at, eventId: row.id) {
            return start
        }

        guard let day = trimmedNonEmpty(row.event_date),
              let time = trimmedNonEmpty(row.event_time),
              time.lowercased() != "time tbd" else {
            return nil
        }

        return DiscoverPreviewDateFormatters.sqlDayWithShortTime.date(from: "\(day) \(time)")
    }

    private func venuePredictionFallbackDay(for row: VenueEventRow) -> Date? {
        guard let day = trimmedNonEmpty(row.event_date) else { return nil }
        return DiscoverPreviewDateFormatters.sqlDay.date(from: day)
    }

    private func venuePredictionFallbackStartDate(for event: SportsEvent) -> Date? {
        let time = event.time.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !time.isEmpty, time.lowercased() != "time tbd" else { return nil }
        return DiscoverPreviewDateFormatters.sqlDayWithShortTime.date(
            from: "\(DiscoverPreviewDateFormatters.sqlDay.string(from: event.date)) \(time)"
        )
    }

    private func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func logVenuePredictionVisibility(_ visibility: DiscoverVenuePredictionVisibility) {
#if DEBUG
        let startsAt = visibility.startsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "nil"
        let lockTime = visibility.lockTime.map { ISO8601DateFormatter().string(from: $0) } ?? "nil"
        print("[VenuePredictionVisibilityDebug] eventId=\(visibility.eventID?.uuidString.lowercased() ?? "nil")")
        print("[VenuePredictionVisibilityDebug] sportType=\(visibility.sportType)")
        print("[VenuePredictionVisibilityDebug] hasHomeTeam=\(visibility.hasHomeTeam)")
        print("[VenuePredictionVisibilityDebug] hasAwayTeam=\(visibility.hasAwayTeam)")
        print("[VenuePredictionVisibilityDebug] predictionVisible=\(visibility.predictionVisible)")
        print("[VenuePredictionVisibilityDebug] startsAt=\(startsAt)")
        print("[VenuePredictionVisibilityDebug] lockTime=\(lockTime)")
        print("[VenuePredictionVisibilityDebug] isLocked=\(visibility.isLocked)")
        print("[VenuePredictionVisibilityDebug] hiddenReason=\(visibility.hiddenReason ?? "none")")
#endif
    }

    private func venuePreviewGoingButton(
        bar: BarVenue,
        event: SportsEvent,
        venueEventID: UUID?,
        alreadyInterested: Bool
    ) -> some View {
        let requiresLogin = !viewModel.isAuthenticatedForSocialFeatures
        let isBlocked = viewModel.isAuthenticatedForSocialFeatures && !viewModel.canMarkGoing
        let missingVenueEventID = venueEventID == nil
        let isPending = venueEventID.map { viewModel.isVenueEventInterestMutationInFlight($0) } ?? false
        let title = requiresLogin ? "Log in" : "Going"
        let activeGoingFill = Color(red: 0.00, green: 0.62, blue: 0.27)
        let activeGoingBorder = Color(red: 0.00, green: 0.38, blue: 0.16)
        let isDisabled = isPending || missingVenueEventID
        let tint = isBlocked || missingVenueEventID ? Color.secondary : (alreadyInterested ? Color.white : FGColor.primaryText(colorScheme))
        let fill = isBlocked || missingVenueEventID
            ? Color.gray.opacity(0.16)
            : (alreadyInterested ? activeGoingFill : discoverPreviewControlBackground)
        let border = isBlocked || missingVenueEventID
            ? tint.opacity(0.18)
            : (alreadyInterested ? activeGoingBorder.opacity(0.82) : tint.opacity(0.26))
        let glow = alreadyInterested && !isBlocked && !missingVenueEventID
            ? FGColor.accentGreen.opacity(colorScheme == .dark ? 0.42 : 0.30)
            : Color.clear

        return Button {
            guard !missingVenueEventID else { return }
            FGInteractionHaptics.softImpact()
            viewModel.toggleVenueGameGoingFromUI(
                bar: bar,
                gameTitle: event.title,
                eventDate: event.date,
                knownVenueEventID: venueEventID,
                source: "discoverVenueGameCard",
                onRequiresLogin: {
                    viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
                },
                onBusinessBlocked: {
                    viewModel.logBusinessUserGateBlocked(action: "markGoing")
                    fanFeatureGateAlertMessage = BusinessFanGateCopy.actionTapBlocked
                }
            )
        } label: {
            HStack(spacing: 5) {
                if isPending {
                    ProgressView()
                        .controlSize(.mini)
                } else if !requiresLogin {
                    Image(systemName: alreadyInterested ? "checkmark.circle.fill" : "checkmark")
                        .font(.caption.weight(.bold))
                }
                Text(title)
                    .font(FGTypography.metadata.weight(.bold))
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background {
                Capsule(style: .continuous)
                    .fill(fill)
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(border, lineWidth: alreadyInterested && !isBlocked && !missingVenueEventID ? 1.35 : 1)
            }
            .overlay {
                if alreadyInterested && !isBlocked && !missingVenueEventID {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.8)
                        .padding(1)
                }
            }
            .shadow(color: glow, radius: 8, x: 0, y: 3)
            .shadow(color: alreadyInterested && !isBlocked && !missingVenueEventID ? Color.black.opacity(0.22) : .clear, radius: 4, x: 0, y: 2)
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.72 : 1)
    }

    private func venueGameCardSocialActionRow(
        venueEventID: UUID,
        previewEnergy: VenueGamePreviewEnergy?,
        fanChatCount: Int? = nil,
        onVenueEnergyInfo: (() -> Void)? = nil
    ) -> some View {
        let source = "discoverVenueGameCard"
        let commentCount = fanChatCount ?? viewModel.fanUpdatesDisplayCommentCount(for: venueEventID)
        let _ = logFanChatEntryUXRendered(source: source, eventId: venueEventID, count: commentCount)
        let _ = logFanReactionRemovedFromVenueCard()

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                if let previewEnergy, previewEnergy.hasBadge {
                    venueGamePreviewEnergyCompactBadge(previewEnergy)
                }

                if let onVenueEnergyInfo {
                    VenueEnergyInfoButton(action: onVenueEnergyInfo)
                }

                Spacer(minLength: 8)

                venueGameFanChatActionButton(
                    venueEventID: venueEventID,
                    source: source,
                    commentCount: commentCount
                )
            }

            if commentCount == 0 {
                Text("Join the game conversation")
                    .font(FGTypography.caption.weight(.medium))
                    .foregroundStyle(discoverPreviewSecondaryTextColor)
                    .lineLimit(1)
            }
        }
    }

    private func venueGamePreviewEnergyCompactBadge(_ energy: VenueGamePreviewEnergy) -> some View {
        let palette = venueGamePreviewEnergyPalette(energy)

        return Text(energy.label ?? "Active")
            .font(FGTypography.metadata.weight(.bold))
            .foregroundStyle(palette.text)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(minHeight: 44)
            .background {
                Capsule(style: .continuous)
                    .fill(energyGradient(for: energy.score))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: palette.borderColors,
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        lineWidth: 1
                    )
            }
            .fixedSize(horizontal: true, vertical: false)
    }

    private func venueGameFanChatActionButton(
        venueEventID: UUID,
        source: String,
        commentCount: Int
    ) -> some View {
        let baseTitle = "Chat"
        let title = commentCount > 0 ? "\(baseTitle) · \(commentCount)" : baseTitle
        let tint = FGColor.accentBlue
        let fill = tint.opacity(colorScheme == .dark ? 0.20 : 0.12)

        return Button {
            print(
                "[FanChatEntryUX] tapped source=\(source) eventId=\(venueEventID.uuidString.lowercased())"
            )
            FGInteractionHaptics.selection()
            presentFanUpdatesSheet(venueEventID: venueEventID)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                Text(title)
                    .font(FGTypography.metadata.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background {
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .background {
                        Capsule(style: .continuous)
                            .fill(fill)
                    }
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(colorScheme == .dark ? 0.34 : 0.26), lineWidth: 1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            commentCount > 0
                ? "Chat, \(commentCount) comments"
                : "Chat"
        )
    }

    private func logFanReactionRemovedFromVenueCard() {
#if DEBUG
        print("[FanReactionDebug] removedFromVenueCard=true")
#endif
    }

    private func venueSupporterBanner(_ supporter: VenueSupporterCountryDisplay) -> some View {
        let colors = venueSupporterBannerColors(for: supporter.countryCode)

        return HStack(spacing: 12) {
            Text(supporter.flag)
                .font(.system(size: 34))
                .frame(width: 48, height: 48)
                .background(Circle().fill(Color.white.opacity(colorScheme == .dark ? 0.15 : 0.78)))

            VStack(alignment: .leading, spacing: 3) {
                Text(supporter.title)
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)

                Text("Tournament crowd mode")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                    .textCase(.uppercase)
                    .tracking(0.4)
            }

            Spacer(minLength: 0)
        }
        .padding(13)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: colors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.black.opacity(colorScheme == .dark ? 0.18 : 0.06))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.24), lineWidth: 1)
        }
        .shadow(color: (colors.first ?? FGColor.accentBlue).opacity(colorScheme == .dark ? 0.28 : 0.18), radius: 14, x: 0, y: 8)
        .onAppear {
#if DEBUG
            print("[VenueSupporterBannerDebug] venueLevelBanner=true")
            print("[VenueSupporterBannerDebug] supporterCountry=\(supporter.storedCountry)")
            print("[VenueSupporterBannerDebug] movedOutsideGameCard=true")
            print("[VenueSupporterDebug] supporterCountry=\(supporter.storedCountry)")
            print("[VenueSupporterDebug] supporterBannerVisible=true")
#endif
        }
    }

    private func venueSupporterBannerColors(for countryCode: String?) -> [Color] {
        switch countryCode {
        case "MX":
            return [Color(red: 0.00, green: 0.46, blue: 0.25), Color(red: 0.78, green: 0.06, blue: 0.15)]
        case "US":
            return [Color(red: 0.05, green: 0.20, blue: 0.56), Color(red: 0.78, green: 0.08, blue: 0.18)]
        case "FR":
            return [Color(red: 0.00, green: 0.16, blue: 0.48), Color(red: 0.86, green: 0.08, blue: 0.20)]
        case "AR":
            return [Color(red: 0.12, green: 0.54, blue: 0.84), Color(red: 0.93, green: 0.75, blue: 0.22)]
        case "BR":
            return [Color(red: 0.00, green: 0.52, blue: 0.27), Color(red: 0.96, green: 0.78, blue: 0.10)]
        default:
            return [FGColor.accentGreen.opacity(0.92), FGColor.accentBlue.opacity(0.90)]
        }
    }

    private func logFanChatEntryUXRendered(source: String, eventId: UUID, count: Int) {
        print(
            "[FanChatEntryUX] rendered source=\(source) eventId=\(eventId.uuidString.lowercased()) count=\(count)"
        )
    }

    private func presentFanUpdatesSheet(venueEventID: UUID, title: String? = nil) {
        guard viewModel.isAuthenticatedForSocialFeatures else {
            viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
            return
        }
        FanUpdatesTapPerf.handleTap(eventId: venueEventID) {
            fanUpdatesSheetEvent = FanUpdatesSheetEvent(id: venueEventID, title: title)
        }
    }

    private var venuePreviewMiniStats: [VenuePreviewMiniStat] {
        [
            VenuePreviewMiniStat(id: "packed", symbol: "🔥", label: "On fire", countColor: .red, background: Color(red: 1.00, green: 0.90, blue: 0.92), selectedBackground: .red.opacity(0.18)),
            VenuePreviewMiniStat(id: "seats_open", symbol: "🪑", label: "Seats", countColor: .green, background: Color(red: 0.90, green: 0.97, blue: 0.91), selectedBackground: .green.opacity(0.18)),
            VenuePreviewMiniStat(id: "tv_visible", symbol: "📺", label: "TVs", countColor: .primary, background: Color(red: 0.90, green: 0.95, blue: 1.00), selectedBackground: .blue.opacity(0.18)),
            VenuePreviewMiniStat(id: "audio_on", symbol: "🔊", label: "Sound", countColor: .orange, background: Color(red: 1.00, green: 0.96, blue: 0.84), selectedBackground: .yellow.opacity(0.24)),
            VenuePreviewMiniStat(id: "crowd", symbol: "👥", label: "Crowd", countColor: .blue, background: Color(red: 0.92, green: 0.93, blue: 1.00), selectedBackground: .blue.opacity(0.16))
        ]
    }

    private func venuePreviewInteractionStrip(venueEventID: UUID) -> some View {
        let counts = fanUpdatesStore.venueEventVibeCounts[venueEventID] ?? [:]
        let selected = fanUpdatesStore.myVenueEventVibes[venueEventID] ?? []
        let _ = logFanUpdatesStoreMigrationDebug()
        let _ = logVenueMiniStatsDebug(eventId: venueEventID, counts: counts)

        return HStack(spacing: 6) {
            ForEach(venuePreviewMiniStats) { stat in
                venuePreviewMiniStatChip(
                    stat,
                    venueEventID: venueEventID,
                    counts: counts,
                    selected: selected
                )
            }
        }
        .padding(.top, 1)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func venuePreviewInteractionStrip(
        venueEventID: UUID,
        miniStats: VenueGameCardMiniStats
    ) -> some View {
        let counts = miniStats.vibeCounts
        let selected = miniStats.selectedVibes
        let _ = logFanUpdatesStoreMigrationDebug()
        let _ = logVenueMiniStatsDebug(eventId: venueEventID, counts: counts)

        return HStack(spacing: 6) {
            ForEach(venuePreviewMiniStats) { stat in
                venuePreviewMiniStatChip(
                    stat,
                    venueEventID: venueEventID,
                    counts: counts,
                    selected: selected
                )
            }
        }
        .padding(.top, 1)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func venuePreviewMiniStatChip(
        _ stat: VenuePreviewMiniStat,
        venueEventID: UUID,
        counts: [String: Int],
        selected: Set<String>
    ) -> some View {
        let count = counts[stat.id] ?? 0
        let isSelected = selected.contains(stat.id)
        return Button {
            FGInteractionHaptics.softImpact()
            guard viewModel.isAuthenticatedForSocialFeatures else {
                viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
                return
            }
            guard viewModel.canUseFanSocialFeatures else {
                viewModel.logBusinessUserGateBlocked(action: "toggleVibe")
                fanFeatureGateAlertMessage = BusinessFanGateCopy.actionTapBlocked
                return
            }
            Task {
                await viewModel.toggleVibe(for: venueEventID, vibeType: stat.id)
            }
        } label: {
            HStack(spacing: 4) {
                Text(stat.symbol)
                    .font(.system(size: 17))
                Text("\(count)")
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(stat.countColor)
            }
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 38, maxHeight: 38)
                .background {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(isSelected ? stat.selectedBackground : stat.background)
                }
        }
        .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.965, hapticOnPress: false))
        .accessibilityLabel("\(stat.label), \(count) votes")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func logVenueMiniStatsDebug(eventId: UUID, counts: [String: Int]) {
#if DEBUG
        guard VenueGameCardDiagnostics.enabled else { return }
        print("[VenueMiniStatsDebug] eventId=\(eventId.uuidString)")
        print("[VenueMiniStatsDebug] counts=packed:\(counts["packed"] ?? 0),seats:\(counts["seats_open"] ?? 0),tv:\(counts["tv_visible"] ?? 0),sound:\(counts["audio_on"] ?? 0),crowd:\(counts["crowd"] ?? 0)")
        print("[VenueMiniStatsDebug] packed=\(counts["packed"] ?? 0)")
        print("[VenueMiniStatsDebug] seats=\(counts["seats_open"] ?? 0)")
        print("[VenueMiniStatsDebug] tv=\(counts["tv_visible"] ?? 0)")
        print("[VenueMiniStatsDebug] sound=\(counts["audio_on"] ?? 0)")
        print("[VenueMiniStatsDebug] crowd=\(counts["crowd"] ?? 0)")
        print("[VenueMiniStatsDebug] rowRendered=true")
#endif
    }

    private func logFanUpdatesStoreMigrationDebug() {
#if DEBUG
        print("[FanUpdatesStoreMigrationDebug] DiscoverObservesStore=true")
        print("[FanUpdatesStoreMigrationDebug] DiscoverPreviewReadsStore=true")
#endif
    }

    private func venuePreviewInteractionTint(for type: String) -> Color {
        switch type {
        case "packed":
            return FGColor.dangerRed
        case "seats_open", "crowd":
            return FGColor.accentGreen
        case "tv_visible":
            return FGColor.accentBlue
        case "audio_on":
            return FGColor.accentYellow
        default:
            return FGColor.accentBlue
        }
    }

    private func venuePreviewEnergy(for venueEventID: UUID, energy: FanGeoLiveEnergy) -> VenueGamePreviewEnergy {
        let counts = fanUpdatesStore.venueEventVibeCounts[venueEventID] ?? [:]
        return venuePreviewEnergy(for: venueEventID, energy: energy, counts: counts)
    }

    private func venuePreviewEnergy(
        for venueEventID: UUID,
        energy: FanGeoLiveEnergy,
        counts: [String: Int]
    ) -> VenueGamePreviewEnergy {
        let previewEnergy = VenueGamePreviewEnergy.evaluate(
            fireCount: counts["packed"] ?? 0,
            seatsCount: counts["seats_open"] ?? 0,
            tvCount: counts["tv_visible"] ?? 0,
            soundCount: counts["audio_on"] ?? 0,
            crowdCount: counts["crowd"] ?? 0,
            goingCount: energy.goingCount,
            friendGoingCount: energy.friendGoingCount,
            commentCount: energy.commentCount,
            isLiveNow: energy.isLiveNow,
            startsSoon: energy.startsSoon
        )
        logVenueEnergyDebug(eventId: venueEventID, energy: previewEnergy)
        return previewEnergy
    }

    private func venueGamePreviewEnergyHeader(_ energy: VenueGamePreviewEnergy) -> some View {
        let palette = venueGamePreviewEnergyPalette(energy)

        return HStack(alignment: .center, spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(energy.label ?? "Quiet")
                    .font(FGTypography.metadata.weight(.bold))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)

                Text(energy.subtitle)
                    .font(FGTypography.caption.weight(.medium))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Capsule(style: .continuous)
                .fill(energyGradient(for: energy.score))
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: palette.borderColors,
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: palette.glowColor, radius: palette.glowRadius, x: 0, y: 3)
    }

    private func venueGamePreviewEnergyPalette(_ energy: VenueGamePreviewEnergy?) -> VenueEnergyColorPalette {
        venueEnergyColorPalette(for: energy?.score ?? 0)
    }

    private func logVenueEnergyDebug(eventId: UUID, energy: VenueGamePreviewEnergy) {
#if DEBUG
        DebugLogGate.noisy("[VenueEnergyDebug] eventId=\(eventId.uuidString.lowercased())")
        DebugLogGate.noisy("[VenueEnergyDebug] score=\(energy.score)")
        DebugLogGate.noisy("[VenueEnergyDebug] label=\(energy.label ?? "none")")
        DebugLogGate.noisy("[VenueEnergyDebug] fire=\(energy.fireCount)")
        DebugLogGate.noisy("[VenueEnergyDebug] crowd=\(energy.crowdCount)")
        DebugLogGate.noisy("[VenueEnergyDebug] going=\(energy.goingCount)")
        DebugLogGate.noisy("[VenueEnergyDebug] friends=\(energy.friendGoingCount)")
        DebugLogGate.noisy("[VenueEnergyDebug] comments=\(energy.commentCount)")
        let palette = venueGamePreviewEnergyPalette(energy)
        DebugLogGate.noisy("[VenueEnergyColorDebug] score=\(energy.score)")
        DebugLogGate.noisy("[VenueEnergyColorDebug] tier=\(palette.tier.rawValue)")
        DebugLogGate.noisy("[VenueEnergyColorDebug] accent=\(String(describing: energyAccentColor(for: energy.score)))")
#endif
    }

    private func liveScoreEmoji(for score: Int) -> String {
        VenueMapEnergyScore.tier(for: score).emoji
    }
    
    
    private func simpleMapPin(
        bar: BarVenue,
        gamesToday: [SportsEvent],
        displayClass: VenuePinDisplayClass
    ) -> some View {
        let sport = gamesToday.first?.sport ?? bar.primarySport
        let tint = mapSportIconTint(for: sport)
        let reusedSportChipIcon = mapSportIconReusesSportChipIcon(sport)
        let isPro = displayClass == .proVenue

        return MapSportChipIconGlyph(
            sport: sport,
            emojiSize: 24,
            symbolSize: 18,
            frameSize: 40
        )
            .frame(width: 40, height: 40)
            .background {
                ZStack {
                    Circle()
                        .fill(
                            isPro
                                ? LinearGradient(
                                    colors: [
                                        Color(red: 0.98, green: 0.78, blue: 0.34),
                                        proVenueGold
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                : LinearGradient(colors: [Color.black, Color.black], startPoint: .top, endPoint: .bottom)
                        )
                        .shadow(color: isPro ? proVenueGold.opacity(0.28) : .black.opacity(0.30), radius: isPro ? 8 : 5, y: isPro ? 2 : 0)
                    Circle()
                        .fill(isPro ? proVenueGlyphInk.opacity(0.14) : (reusedSportChipIcon ? tint.opacity(0.22) : Color.white.opacity(0.08)))
                        .frame(width: 31, height: 31)
                }
            }
            .overlay {
                Circle()
                    .strokeBorder(
                        (isPro ? proVenueGoldDeep : (reusedSportChipIcon ? tint : Color.white)).opacity(isPro ? 0.48 : 0.34),
                        lineWidth: isPro ? 1.25 : 1
                    )
                    .padding(4)
            }
            .onAppear {
                logMapSportIconDebug(sport: sport, markerType: "venue")
            }
    }

    private func noGameScheduledMapPin(displayClass: VenuePinDisplayClass) -> some View {
        let isUnclaimedCommunity = displayClass == .unclaimedCommunity
        let isPro = displayClass == .proVenue
        let fill: Color = {
            if isPro {
                return proVenueGold
            }
            if isUnclaimedCommunity {
                return Color.gray.opacity(0.62)
            }
            return colorScheme == .dark ? Color(red: 0.03, green: 0.06, blue: 0.09) : Color(red: 0.02, green: 0.05, blue: 0.08)
        }()
        let stroke: Color = isPro
            ? Color(red: 1.0, green: 0.86, blue: 0.46).opacity(0.72)
            : Color.white.opacity(isUnclaimedCommunity ? 0.18 : 0.28)

        return Image(systemName: "building.2.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(isPro ? proVenueGlyphInk.opacity(0.88) : Color.white.opacity(0.92))
            .frame(width: 38, height: 38)
            .background(
                Circle()
                    .fill(fill)
                    .shadow(
                        color: isPro ? proVenueGold.opacity(colorScheme == .dark ? 0.34 : 0.24) : .black.opacity(0.18),
                        radius: isPro ? 10 : 4,
                        y: isPro ? 3 : 0
                    )
            )
            .overlay {
                Circle()
                    .strokeBorder(stroke, lineWidth: isPro ? 1.2 : 0.8)
            }
            .opacity(isUnclaimedCommunity ? 0.6 : 0.95)
    }

    private func compactMapPin(
        bar: BarVenue,
        gamesToday: [SportsEvent],
        goingTotal: Int,
        liveScore: Int? = nil,
        hasLiveNow: Bool? = nil,
        displayClass: VenuePinDisplayClass
    ) -> some View {
        let liveScore = liveScore ?? liveActivityScore(for: bar, gamesToday: gamesToday)
        let hasLiveNow = hasLiveNow ?? viewModel.hasLiveVenueEventNow(for: bar, events: gamesToday)
        let isPro = displayClass == .proVenue

        let sport = gamesToday.first?.sport ?? bar.primarySport
        let sportTint = mapSportIconTint(for: sport)
        let reusedSportChipIcon = mapSportIconReusesSportChipIcon(sport)

        return HStack(spacing: 6) {
            MapSportChipIconGlyph(
                sport: sport,
                emojiSize: 18,
                symbolSize: 15,
                frameSize: 22
            )
            .background(Circle().fill(isPro ? proVenueGlyphInk.opacity(0.13) : (reusedSportChipIcon ? sportTint : Color.white).opacity(0.16)))

            if hasLiveNow {
                Text("LIVE")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(isPro ? proVenueGlyphInk.opacity(0.92) : .white)
            } else if liveScore > 0 {
                let energyLabel = VenueEnergyEducation.displayLabel(forMapEnergyScore: liveScore)
                Text(energyLabel.isEmpty ? liveScoreEmoji(for: liveScore) : energyLabel)
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(isPro ? proVenueGlyphInk.opacity(0.92) : .white)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            ZStack {
                if isDiscoverTabSelected && (hasLiveNow || liveScore >= livePulseThreshold) {
                    LivePulseView(
                        isTrending: hasLiveNow || VenueMapEnergyScore.tier(for: liveScore).isTrendingPulse
                    )
                }

                Capsule()
                    .fill(
                        isPro
                            ? LinearGradient(
                                colors: [
                                    Color(red: 0.98, green: 0.78, blue: 0.34),
                                    proVenueGold
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            : LinearGradient(colors: [Color.black, Color.black], startPoint: .top, endPoint: .bottom)
                    )
                    .shadow(color: isPro ? proVenueGold.opacity(0.26) : .black.opacity(0.26), radius: isPro ? 8 : 5, y: isPro ? 2 : 0)
            }
        }
        .onAppear {
            logMapSportIconDebug(sport: sport, markerType: "venue")
        }
    }
    
    private func liveActivityScore(for bar: BarVenue, gamesToday: [SportsEvent]) -> Int {
        viewModel.mapPinEnergyScore(bar: bar, gamesOnMapDay: gamesToday)
    }

    private func venuePinDisplayState(_ venue: BarVenue) -> VenuePinDisplayState {
        if let pinSnapshot = viewModel.discoverMapRenderSnapshot.venuePinsByID[venue.id] {
#if DEBUG
            DebugLogGate.noisy("[DiscoverMapSnapshotDebug] usingPinSnapshot=true")
#endif
            return pinSnapshot.selectedDayGames.isEmpty ? .noGameScheduled : .gameScheduled
        }

        return viewModel.venueHasVisibleGameToday(venue) ? .gameScheduled : .noGameScheduled
    }

    private func clusterDisplayState(_ cluster: VenueCluster) -> ClusterDisplayState {
        let snapshot = viewModel.discoverMapRenderSnapshot
        if let clusterSnapshot = snapshot.venueClustersByID[cluster.id] {
            let pinSnapshots = clusterSnapshot.venueIDs.compactMap { snapshot.venuePinsByID[$0] }
            if pinSnapshots.count == clusterSnapshot.venueIDs.count {
#if DEBUG
                DebugLogGate.noisy("[DiscoverMapSnapshotDebug] usingClusterSnapshot=true")
#endif
                return pinSnapshots.contains { !$0.selectedDayGames.isEmpty } ? .gameScheduled : .noGameScheduled
            }
        }

        return cluster.bars.contains { viewModel.venueHasVisibleGameToday($0) } ? .gameScheduled : .noGameScheduled
    }

    private func detailedMapPin(
        bar: BarVenue,
        gamesToday: [SportsEvent],
        goingTotal: Int,
        liveScore: Int? = nil,
        hasLiveNow: Bool? = nil,
        displayClass: VenuePinDisplayClass
    ) -> some View {
        
        VStack(spacing: 4) {
            let hasLiveNow = hasLiveNow ?? viewModel.hasLiveVenueEventNow(for: bar, events: gamesToday)
            let liveScore = liveScore ?? liveActivityScore(for: bar, gamesToday: gamesToday)
            let isPro = displayClass == .proVenue
            HStack(spacing: -6) {
                ForEach(gamesToday.prefix(3), id: \.id) { game in
                    let sportTint = mapSportIconTint(for: game.sport)
                    let reusedSportChipIcon = mapSportIconReusesSportChipIcon(game.sport)
                    MapSportChipIconGlyph(
                        sport: game.sport,
                        emojiSize: 22,
                        symbolSize: 17,
                        frameSize: 36
                    )
                        .frame(width: 36, height: 36)
                        .background {
                            ZStack {
                                if isDiscoverTabSelected && (hasLiveNow || liveScore >= livePulseThreshold) {
                                    LivePulseView(
                                        isTrending: hasLiveNow || VenueMapEnergyScore.tier(for: liveScore).isTrendingPulse
                                    )
                                }

                                Circle()
                                    .fill(isPro ? proVenueGold : Color.black)
                                    .shadow(color: isPro ? proVenueGold.opacity(0.26) : .black.opacity(0.26), radius: isPro ? 8 : 5, y: isPro ? 2 : 0)
                                Circle()
                                    .fill(isPro ? proVenueGlyphInk.opacity(0.13) : (reusedSportChipIcon ? sportTint : Color.white).opacity(0.16))
                                    .padding(6)
                            }
                        }
                        .overlay {
                            Circle()
                                .strokeBorder(
                                    (isPro ? proVenueGoldDeep : (reusedSportChipIcon ? sportTint : Color.white)).opacity(isPro ? 0.46 : 0.30),
                                    lineWidth: isPro ? 1.15 : 1
                                )
                                .padding(3)
                        }
                        .onAppear {
                            logMapSportIconDebug(sport: game.sport, markerType: "venue")
                        }
                }
            }
            Text(gamesToday.count == 1 ? AppSportCatalog.displayLabel(forSportToken: gamesToday.first?.sport ?? bar.primarySport) : "\(gamesToday.count) games")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundStyle(isPro ? proVenueGlyphInk.opacity(0.92) : .white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isPro ? proVenueGold.opacity(0.92) : Color.black.opacity(0.75))
                .clipShape(Capsule())

            if hasLiveNow || liveScore > 0 {
                let energyLabel = VenueEnergyEducation.displayLabel(forMapEnergyScore: liveScore)
                Text(hasLiveNow ? "LIVE NOW" : (energyLabel.isEmpty ? "Active" : energyLabel))
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((hasLiveNow ? FGColor.dangerRed : Color.orange).opacity(0.95))
                    .clipShape(Capsule())
            }

            Text(bar.name)
                .font(.caption2)
                .foregroundStyle(.primary)
        }
    }
    
    private var loadingVenueGamesView: some View {
        HStack(spacing: FGSpacing.sm) {
            ProgressView()
                .scaleEffect(0.85)

            Text("Loading venue games...")
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
        }
        .padding(FGSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.60 : 0.92))
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
    }
        
    
    private func clusterMapPin(
        cluster: VenueCluster,
        maxEnergy: Int,
        dominantSport: String?,
        displayState: ClusterDisplayState,
        displayClass: VenuePinDisplayClass
    ) -> some View {
        let caption = viewModel.mapClusterEnergyCaption(maxScore: maxEnergy)
        let isUnclaimedCommunity = displayClass == .unclaimedCommunity
        let isPro = displayClass == .proVenue
        let useDarkFill = !isUnclaimedCommunity || displayState == .gameScheduled
        let fill = useDarkFill ? Color.black : Color.gray.opacity(0.72)
        let iconBackground = isPro ? proVenueGold.opacity(0.22) : (useDarkFill ? Color.white.opacity(0.13) : Color.gray.opacity(0.8))

        return VStack(spacing: 3) {
                if case .gameScheduled = displayState,
                   let sport = dominantSport,
                   maxEnergy > 0 {
                    let sportTint = mapSportIconTint(for: sport)
                    let reusedSportChipIcon = mapSportIconReusesSportChipIcon(sport)
                    MapSportChipIconGlyph(
                        sport: sport,
                        emojiSize: 20,
                        symbolSize: 15,
                        frameSize: 26
                    )
                        .padding(5)
                        .background(Circle().fill(isPro ? proVenueGold.opacity(0.22) : (reusedSportChipIcon ? sportTint : Color.white).opacity(0.16)))
                        .onAppear {
                            logMapSportIconDebug(sport: sport, markerType: "venueCluster")
                        }
                } else if case .noGameScheduled = displayState {
                    Image(systemName: "building.2.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .padding(5)
                        .background(Circle().fill(iconBackground))
                }

                Text("\(cluster.count)")
                    .font(.headline)
                    .fontWeight(.bold)

                Text("venues")
                    .font(.caption2)
                    .fontWeight(.bold)

                if case .gameScheduled = displayState, let caption {
                    Text(caption)
                        .font(.system(size: 9, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 6)
            .padding(.vertical, 7)
            .frame(minWidth: 58, minHeight: 58)
            .background(
                Circle()
                    .fill(fill)
                    .shadow(color: isPro ? proVenueGold.opacity(colorScheme == .dark ? 0.32 : 0.22) : .black.opacity(0.18), radius: isPro ? 9 : 7, y: 2)
            )
            .overlay {
                Circle()
                    .strokeBorder(
                        isPro ? proVenueGold.opacity(0.78) : Color.white.opacity(useDarkFill ? 0.22 : 0.10),
                        lineWidth: isPro ? 1.4 : 0.8
                    )
            }
            .opacity(useDarkFill ? 1 : 0.62)
    }

    private func topVibeText(for venueEventID: UUID) -> String? {
        let counts = fanUpdatesStore.venueEventVibeCounts[venueEventID] ?? [:]

        guard let top = counts.max(by: { $0.value < $1.value }),
              top.value > 0 else {
            return nil
        }

        switch top.key {
        case "audio_on":
            return "🔊 Audio confirmed · \(top.value)"
        case "packed":
            return "🔥 Packed · \(top.value)"
        case "seats_open":
            return "🪑 Seats open · \(top.value)"
        case "specials":
            return "🍺 Specials · \(top.value)"
        case "tv_visible":
            return "📺 TVs visible · \(top.value)"
        case "crowd":
            return "👥 Crowd checked · \(top.value)"
        default:
            return nil
        }
    }

}

// MARK: - Discover light overlay chrome

private enum DiscoverOverlaySportChip: String, CaseIterable, Identifiable {
    case allSports
    case soccer
    case basketball
    case football
    case tennis
    case baseball
    case more

    var id: String { rawValue }

    var selection: String {
        switch self {
        case .allSports: return "All"
        case .soccer: return "Soccer"
        case .basketball: return "NBA"
        case .football: return "NFL"
        case .tennis: return "Tennis"
        case .baseball: return "Baseball"
        case .more: return "More"
        }
    }

    var label: String {
        switch self {
        case .allSports: return "All Sports"
        case .soccer: return "Soccer"
        case .basketball: return "Basketball"
        case .football: return "Football"
        case .tennis: return "Tennis"
        case .baseball: return "Baseball"
        case .more: return "More"
        }
    }

    static func isPinnedPopularSelection(_ selectedSport: String) -> Bool {
        let trimmed = selectedSport.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "All" { return true }
        return allCases.contains { chip in
            chip != .more && DiscoverSportFilterRowLayout.selectionTokensMatch(trimmed, chip.selection)
        }
    }
}

private struct DiscoverOverlaySportPillRow: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var showMoreSheet: Bool
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if !DiscoverOverlaySportChip.isPinnedPopularSelection(viewModel.selectedSport) {
                DiscoverOverlaySportPill(
                    selection: viewModel.selectedSport,
                    label: viewModel.selectedSport == viewModel.selectedSport.lowercased()
                        ? AppSportCatalog.displayLabel(forSportToken: viewModel.selectedSport)
                        : viewModel.selectedSport,
                    isSelected: true,
                    action: { onSelect(viewModel.selectedSport) }
                )
            }

            ForEach(DiscoverOverlaySportChip.allCases) { chip in
                if chip == .more {
                    DiscoverOverlaySportPill(
                        selection: "More",
                        label: chip.label,
                        isSelected: false,
                        action: { showMoreSheet = true }
                    )
                } else {
                    DiscoverOverlaySportPill(
                        selection: chip.selection,
                        label: chip.label,
                        isSelected: DiscoverSportFilterRowLayout.selectionTokensMatch(
                            viewModel.selectedSport,
                            chip.selection
                        ),
                        action: { onSelect(chip.selection) }
                    )
                }
            }
        }
    }
}

private struct DiscoverOverlaySportPill: View {
    @Environment(\.colorScheme) private var colorScheme

    let selection: String
    let label: String
    let isSelected: Bool
    let action: () -> Void

    private static let chipHeight: CGFloat = 36
    private static let chipCornerRadius: CGFloat = 18
    private static let chipSymbolPointSize: CGFloat = 13
    private static let chipEmojiPointSize: CGFloat = 15

    private var visual: SportFilterCatalog.ChipVisual {
        SportFilterCatalog.resolve(selection)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Group {
                    if selection == "All" {
                        Image(systemName: visual.systemImage)
                            .font(.system(size: Self.chipSymbolPointSize, weight: .semibold))
                            .foregroundStyle(visual.accent)
                    } else if selection == "More" {
                        Image(systemName: "ellipsis")
                            .font(.system(size: Self.chipSymbolPointSize, weight: .bold))
                            .foregroundStyle(FGColor.mutedText(colorScheme))
                    } else if !visual.emoji.isEmpty {
                        Text(visual.emoji)
                            .font(.system(size: Self.chipEmojiPointSize))
                            .frame(width: 15, height: 15)
                            .minimumScaleFactor(0.85)
                            .lineLimit(1)
                    } else {
                        Image(systemName: visual.systemImage)
                            .font(.system(size: Self.chipSymbolPointSize, weight: .semibold))
                            .foregroundStyle(visual.accent)
                    }
                }

                Text(label)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(colorScheme == .dark ? Color.white.opacity(isSelected ? 0.96 : 0.86) : FGColor.primaryText(colorScheme))
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .frame(height: Self.chipHeight)
            .background {
                RoundedRectangle(cornerRadius: Self.chipCornerRadius, style: .continuous)
                    .fill(colorScheme == .dark ? .thinMaterial : .ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.chipCornerRadius, style: .continuous)
                            .fill(colorScheme == .dark ? Color.black.opacity(isSelected ? 0.24 : 0.34) : Color.clear)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.chipCornerRadius, style: .continuous)
                            .fill(
                                Color.white.opacity(
                                    isSelected
                                        ? (colorScheme == .dark ? 0.18 : 0.62)
                                        : (colorScheme == .dark ? 0.10 : 0.44)
                                )
                            )
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: Self.chipCornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? FGColor.accentGreen
                            : (colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.04)),
                        lineWidth: isSelected ? 1.25 : (colorScheme == .dark ? 0.75 : 0.5)
                    )
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.14 : 0.025),
                radius: colorScheme == .dark ? 3 : 1,
                y: colorScheme == .dark ? 1.5 : 0.5
            )
        }
        .buttonStyle(.plain)
    }
}

private enum DiscoverGlassChromeStyle {
    /// Lighter floating chrome for map-adjacent top overlays.
    case overlay
    case searchBar
    case sportsRow
    case weather
    /// Preserves prior heavier glass for bottom controls (unchanged layout).
    case bottomControl
}

private struct DiscoverLightGlassCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    let style: DiscoverGlassChromeStyle

    private var material: Material {
        switch style {
        case .searchBar, .bottomControl:
            return .thinMaterial
        case .sportsRow, .weather, .overlay:
            return .ultraThinMaterial
        }
    }

    /// Translucent white tint stacked on material (final top lightening pass).
    private var whiteOverlayOpacity: CGFloat {
        switch style {
        case .searchBar:
            return colorScheme == .dark ? 0.17 : 0.44
        case .sportsRow:
            return colorScheme == .dark ? 0.10 : 0.26
        case .weather:
            return colorScheme == .dark ? 0.13 : 0.30
        case .overlay:
            return colorScheme == .dark ? 0.16 : 0.39
        case .bottomControl:
            return colorScheme == .dark ? 0.09 : 0.78
        }
    }

    private var darkSeparationScrimOpacity: CGFloat {
        guard colorScheme == .dark else { return 0 }
        switch style {
        case .searchBar:
            return 0.30
        case .sportsRow:
            return 0.18
        case .weather, .overlay:
            return style == .weather ? 0.20 : 0.28
        case .bottomControl:
            return 0.26
        }
    }

    private var borderColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(style == .bottomControl ? 0.18 : 0.15)
            : FGColor.divider(colorScheme).opacity(style == .bottomControl ? 0.70 : 0.78)
    }

    private var shadowOpacity: Double {
        switch style {
        case .searchBar:
            return colorScheme == .dark ? 0.24 : 0.081
        case .sportsRow:
            return colorScheme == .dark ? 0.12 : 0.032
        case .weather, .overlay:
            return style == .weather ? (colorScheme == .dark ? 0.12 : 0.038) : (colorScheme == .dark ? 0.22 : 0.072)
        case .bottomControl:
            return colorScheme == .dark ? 0.18 : 0.055
        }
    }

    private var shadowRadius: CGFloat {
        switch style {
        case .searchBar:
            return 6
        case .sportsRow:
            return 3
        case .weather, .overlay:
            return style == .weather ? 3 : 5
        case .bottomControl:
            return 8
        }
    }

    private var shadowYOffset: CGFloat {
        switch style {
        case .searchBar:
            return 2
        case .sportsRow:
            return 1.5
        case .weather, .overlay:
            return style == .weather ? 1.5 : 2
        case .bottomControl:
            return 3
        }
    }

    private var showsSpecularHighlight: Bool {
        switch style {
        case .searchBar, .weather, .overlay:
            return true
        case .sportsRow, .bottomControl:
            return false
        }
    }

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(material)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color.black.opacity(darkSeparationScrimOpacity))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color.white.opacity(whiteOverlayOpacity))
                    }
                    .overlay {
                        if showsSpecularHighlight {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(colorScheme == .dark ? 0.09 : 0.19),
                                            Color.white.opacity(0.02)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        }
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: colorScheme == .dark ? 1 : 0.75)
            }
            .shadow(
                color: Color.black.opacity(shadowOpacity),
                radius: shadowRadius,
                y: shadowYOffset
            )
    }
}

private struct DiscoverFloatingMapCircleButtonModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let fill: AnyShapeStyle

    func body(content: Content) -> some View {
        content
            .frame(width: 44, height: 44)
            .background {
                Circle()
                    .fill(fill)
            }
            .overlay {
                Circle()
                    .strokeBorder(Color.black.opacity(colorScheme == .dark ? 0.12 : 0.06), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.12), radius: 10, y: 4)
    }
}

private enum DiscoverHelpPageStyle {
    case welcome
    case feature
}

private struct DiscoverHelpHeroCallout: Identifiable, Equatable {
    let id: String
    let emoji: String
    /// Localization key for the callout label.
    let labelKey: String
}

private struct DiscoverHelpFeatureHighlight: Identifiable, Equatable {
    let id: String
    let titleKey: String
    let detailKey: String
    let systemImage: String
    let accentColor: Color
}

private struct DiscoverHelpCarouselPage: Identifiable {
    let id: Int
    let style: DiscoverHelpPageStyle
    /// Localization keys (empty means unused).
    let welcomeLineKey: String
    let taglineKey: String
    let titleKey: String
    let titleForcesUppercase: Bool
    let primaryTextKey: String
    let secondaryTextKey: String
    let bulletKeys: [String]
    let featureHighlights: [DiscoverHelpFeatureHighlight]
    let heroCallouts: [DiscoverHelpHeroCallout]
    let proTipTitleKey: String
    let proTipBodyKey: String
    let footerTextKey: String
    let systemImage: String
    let accentColor: Color
    let gradientColors: [Color]

    func localizedText(_ key: String, languageCode: String) -> String {
        guard !key.isEmpty else { return "" }
        return L10n.t(key, languageCode: languageCode)
    }

    func welcomeLine(languageCode: String) -> String {
        localizedText(welcomeLineKey, languageCode: languageCode)
    }

    func tagline(languageCode: String) -> String {
        localizedText(taglineKey, languageCode: languageCode)
    }

    func title(languageCode: String) -> String {
        let value = localizedText(titleKey, languageCode: languageCode)
        guard !value.isEmpty else { return "" }
        if titleForcesUppercase {
            return value.uppercased(with: Locale(identifier: languageCode))
        }
        return value
    }

    func primaryText(languageCode: String) -> String {
        localizedText(primaryTextKey, languageCode: languageCode)
    }

    func secondaryText(languageCode: String) -> String {
        localizedText(secondaryTextKey, languageCode: languageCode)
    }

    func bulletPoints(languageCode: String) -> [String] {
        bulletKeys.map { localizedText($0, languageCode: languageCode) }.filter { !$0.isEmpty }
    }

    func footerText(languageCode: String) -> String {
        localizedText(footerTextKey, languageCode: languageCode)
    }

    func proTipTitle(languageCode: String) -> String {
        localizedText(proTipTitleKey, languageCode: languageCode)
    }

    func proTipBody(languageCode: String) -> String {
        localizedText(proTipBodyKey, languageCode: languageCode)
    }

    static let pages: [DiscoverHelpCarouselPage] = [
        DiscoverHelpCarouselPage(
            id: 0,
            style: .welcome,
            welcomeLineKey: "guide_welcome_title",
            taglineKey: "guide_welcome_tagline",
            titleKey: "",
            titleForcesUppercase: false,
            primaryTextKey: "guide_welcome_quick_tour",
            secondaryTextKey: "guide_welcome_body",
            bulletKeys: [
                "guide_welcome_bullet_1",
                "guide_welcome_bullet_2",
                "guide_welcome_bullet_3"
            ],
            featureHighlights: [],
            heroCallouts: [],
            proTipTitleKey: "",
            proTipBodyKey: "",
            footerTextKey: "",
            systemImage: "sportscourt.fill",
            accentColor: FGColor.accentGreen,
            gradientColors: [FGColor.accentGreen, FGColor.accentBlue]
        ),
        DiscoverHelpCarouselPage(
            id: 1,
            style: .feature,
            welcomeLineKey: "",
            taglineKey: "",
            titleKey: "discover",
            titleForcesUppercase: false,
            primaryTextKey: "guide_discover_primary",
            secondaryTextKey: "",
            bulletKeys: [
                "guide_discover_bullet_1",
                "guide_discover_bullet_2",
                "guide_discover_bullet_3"
            ],
            featureHighlights: [],
            heroCallouts: [],
            proTipTitleKey: "",
            proTipBodyKey: "",
            footerTextKey: "",
            systemImage: "map.fill",
            accentColor: FGColor.accentGreen,
            gradientColors: [FGColor.accentGreen, FGColor.accentBlue]
        ),
        DiscoverHelpCarouselPage(
            id: 2,
            style: .feature,
            welcomeLineKey: "",
            taglineKey: "",
            titleKey: "live",
            titleForcesUppercase: false,
            primaryTextKey: "guide_live_primary",
            secondaryTextKey: "",
            bulletKeys: [
                "guide_live_bullet_1",
                "guide_live_bullet_2",
                "guide_live_bullet_3"
            ],
            featureHighlights: [],
            heroCallouts: [],
            proTipTitleKey: "",
            proTipBodyKey: "",
            footerTextKey: "",
            systemImage: "dot.radiowaves.left.and.right",
            accentColor: FGColor.dangerRed,
            gradientColors: [Color(red: 0.98, green: 0.42, blue: 0.32), FGColor.dangerRed]
        ),
        DiscoverHelpCarouselPage(
            id: 3,
            style: .feature,
            welcomeLineKey: "",
            taglineKey: "",
            titleKey: "calendar",
            titleForcesUppercase: false,
            primaryTextKey: "guide_calendar_primary",
            secondaryTextKey: "",
            bulletKeys: [
                "guide_calendar_bullet_1",
                "guide_calendar_bullet_2",
                "guide_calendar_bullet_3"
            ],
            featureHighlights: [],
            heroCallouts: [],
            proTipTitleKey: "",
            proTipBodyKey: "",
            footerTextKey: "",
            systemImage: "calendar.badge.clock",
            accentColor: Color(red: 0.58, green: 0.42, blue: 0.94),
            gradientColors: [Color(red: 0.58, green: 0.42, blue: 0.94), Color(red: 0.72, green: 0.48, blue: 0.98)]
        ),
        DiscoverHelpCarouselPage(
            id: 4,
            style: .feature,
            welcomeLineKey: "",
            taglineKey: "",
            titleKey: "going",
            titleForcesUppercase: false,
            primaryTextKey: "guide_going_primary",
            secondaryTextKey: "",
            bulletKeys: [
                "guide_going_bullet_1",
                "guide_going_bullet_2",
                "guide_going_bullet_3"
            ],
            featureHighlights: [],
            heroCallouts: [],
            proTipTitleKey: "",
            proTipBodyKey: "",
            footerTextKey: "",
            systemImage: "heart.fill",
            accentColor: FGColor.accentGreen,
            gradientColors: [FGColor.accentGreen, Color(red: 0.16, green: 0.62, blue: 0.48)]
        ),
        DiscoverHelpCarouselPage(
            id: 5,
            style: .feature,
            welcomeLineKey: "",
            taglineKey: "",
            titleKey: "chat",
            titleForcesUppercase: false,
            primaryTextKey: "guide_chat_primary",
            secondaryTextKey: "",
            bulletKeys: [
                "guide_chat_bullet_1",
                "guide_chat_bullet_2",
                "guide_chat_bullet_3"
            ],
            featureHighlights: [],
            heroCallouts: [],
            proTipTitleKey: "",
            proTipBodyKey: "",
            footerTextKey: "",
            systemImage: "bubble.left.and.bubble.right.fill",
            accentColor: FGColor.accentBlue,
            gradientColors: [FGColor.accentBlue, Color(red: 0.28, green: 0.52, blue: 0.92)]
        ),
        DiscoverHelpCarouselPage(
            id: 6,
            style: .feature,
            welcomeLineKey: "",
            taglineKey: "",
            titleKey: "profile",
            titleForcesUppercase: false,
            primaryTextKey: "guide_profile_primary",
            secondaryTextKey: "",
            bulletKeys: [
                "guide_profile_bullet_1",
                "guide_profile_bullet_2",
                "guide_profile_bullet_3"
            ],
            featureHighlights: [],
            heroCallouts: [
                DiscoverHelpHeroCallout(id: "teams", emoji: "🏆", labelKey: "favorite_teams"),
                DiscoverHelpHeroCallout(id: "fans", emoji: "👥", labelKey: "suggested_fans"),
                DiscoverHelpHeroCallout(id: "reputation", emoji: "⭐", labelKey: "guide_profile_callout_reputation")
            ],
            proTipTitleKey: "",
            proTipBodyKey: "",
            footerTextKey: "",
            systemImage: "person.crop.circle.fill",
            accentColor: FGColor.accentGreen,
            gradientColors: [FGColor.accentGreen, Color(red: 0.16, green: 0.62, blue: 0.48)]
        )
    ]
}

struct DiscoverHelpSheet: View {
    var personalizedDisplayName: String? = nil
    var accountUserId: UUID? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @State private var hideStartupGuideAtStartup = false
    @State private var selectedPage = 0
    @State private var sheetDetent: PresentationDetent = .fraction(0.90)

    private var pages: [DiscoverHelpCarouselPage] { DiscoverHelpCarouselPage.pages }
    private var languageCode: String { L10n.normalizedLanguageCode(appLanguageRaw) }

    private var isLastPage: Bool { selectedPage >= pages.count - 1 }

    private var primaryButtonTitle: String {
        isLastPage
            ? L10n.t("guide_start_exploring", languageCode: languageCode)
            : L10n.t("guide_next", languageCode: languageCode)
    }

    var body: some View {
        GeometryReader { geo in
            let footerHeight: CGFloat = 136
            let carouselHeight = max(geo.size.height - footerHeight, 420)

            VStack(spacing: 0) {
                TabView(selection: $selectedPage) {
                    ForEach(pages) { page in
                        DiscoverHelpCarouselCard(
                            page: page,
                            contentHeight: carouselHeight,
                            personalizedDisplayName: page.id == 0 ? personalizedDisplayName : nil,
                            languageCode: languageCode
                        )
                            .tag(page.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: carouselHeight)
                .accessibilityLabel(L10n.t("FanGeo onboarding", languageCode: languageCode))
                .accessibilityValue(
                    String(
                        format: L10n.t("guide_page_of_format", languageCode: languageCode),
                        locale: Locale(identifier: languageCode),
                        selectedPage + 1,
                        pages.count
                    )
                    + ", "
                    + (
                        pages[selectedPage].title(languageCode: languageCode).isEmpty
                            ? pages[selectedPage].welcomeLine(languageCode: languageCode)
                            : pages[selectedPage].title(languageCode: languageCode)
                    )
                )

                DiscoverHelpPageIndicator(pageCount: pages.count, selectedPage: selectedPage)
                    .padding(.top, 2)
                    .padding(.bottom, 6)
                    .accessibilityHidden(true)

                Button {
                    // Semantics: checked == hideStartupGuide == true ("Don't show this guide at startup").
                    hideStartupGuideAtStartup.toggle()
                    FanGeoStartupGuidePreferences.setShouldHideAtStartup(
                        hideStartupGuideAtStartup,
                        for: accountUserId
                    )
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: hideStartupGuideAtStartup ? "checkmark.square.fill" : "square")
                            .font(.title3)
                            .foregroundStyle(
                                hideStartupGuideAtStartup
                                    ? FGColor.accentGreen
                                    : FGColor.mutedText(colorScheme)
                            )
                        Text(L10n.t("Don't show this guide at startup", languageCode: languageCode))
                            .font(FGTypography.body)
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, FGSpacing.lg)
                .padding(.bottom, 8)
                .accessibilityAddTraits(hideStartupGuideAtStartup ? .isSelected : [])
                .accessibilityHint(L10n.t("guide_hide_at_startup_hint", languageCode: languageCode))

                FGPrimaryButton(title: primaryButtonTitle) {
                    if isLastPage {
                        dismiss()
                    } else {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            selectedPage += 1
                        }
                    }
                }
                .padding(.horizontal, FGSpacing.lg)
                .padding(.bottom, 12)
                .accessibilityHint(
                    isLastPage
                        ? L10n.t("guide_close_hint", languageCode: languageCode)
                        : L10n.t("guide_next_hint", languageCode: languageCode)
                )
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .background(FGAdaptiveSurface.sheetRoot)
        .presentationDetents([.fraction(0.90), .large], selection: $sheetDetent)
        .presentationDragIndicator(.visible)
        .presentationBackground(FGAdaptiveSurface.sheetRoot)
        .onAppear {
            reloadHideStartupGuidePreference()
        }
        .onChange(of: accountUserId) { _, _ in
            reloadHideStartupGuidePreference()
        }
        .id(languageCode)
    }

    private func reloadHideStartupGuidePreference() {
        // Missing account-scoped key ⇒ false (unchecked). Never auto-write on appear/dismiss.
        hideStartupGuideAtStartup = FanGeoStartupGuidePreferences.shouldHideAtStartup(for: accountUserId)
    }
}

private struct DiscoverHelpPageIndicator: View {
    let pageCount: Int
    let selectedPage: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<pageCount, id: \.self) { index in
                Circle()
                    .fill(
                        index == selectedPage
                            ? FGColor.accentGreen
                            : FGColor.mutedText(colorScheme).opacity(colorScheme == .dark ? 0.35 : 0.28)
                    )
                    .frame(width: index == selectedPage ? 8 : 7, height: index == selectedPage ? 8 : 7)
                    .animation(.easeInOut(duration: 0.2), value: selectedPage)
            }
        }
    }
}

private enum DiscoverHelpCarouselLayout {
    static let heroHeightFraction: CGFloat = 0.425
    static let heroWidthFraction: CGFloat = 0.875
    static let discoverHeroWidthFraction: CGFloat = 0.97
    static let welcomeHeroWidthFraction: CGFloat = 0.98
    static let discoverWelcomeHeroHeightFraction: CGFloat = 0.35
    static let discoverHeroHeightFraction: CGFloat = 0.48
    static let welcomeHeroHeightFraction: CGFloat = 0.48
    static let welcomeHeroMaxDisplayedHeight: CGFloat = 270
    static let discoverHeroMaxDisplayedHeight: CGFloat = 270
    static let welcomeHeroHorizontalInset: CGFloat = 4
    static let discoverHeroHorizontalInset: CGFloat = 4
    static let discoverWelcomeHeroVerticalInset: CGFloat = 10
    static let welcomeHeroTopInset: CGFloat = 4
    static let discoverHeroTopInset: CGFloat = 4
    static let welcomeHeroToCopySpacing: CGFloat = 10
    static let discoverHeroToCopySpacing: CGFloat = 10
    static let discoverWelcomeHeroCornerRadius: CGFloat = 14
    static let welcomeHeroZoomTransitionID = "welcome-onboarding-hero"
    static let discoverHeroZoomTransitionID = "discover-onboarding-hero"
    static let discoverHeroTargetHeight: CGFloat = 260
    static let discoverHeroCopyReserve: CGFloat = 272
    static let welcomeCopySpacing: CGFloat = 6
    static let sectionSpacing: CGFloat = 5
    static let copySpacing: CGFloat = 3
}

private struct DiscoverHelpCarouselCard: View {
    let page: DiscoverHelpCarouselPage
    let contentHeight: CGFloat
    var personalizedDisplayName: String? = nil
    var languageCode: String = L10n.defaultLanguageCode
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var premiumHeroZoomNamespace
    @State private var showPremiumHeroFullscreen = false

    private var isDiscoverWelcomePage: Bool { page.id == 0 }
    private var isDiscoverOnboardingPage: Bool { page.id == 1 }
    private var usesPremiumHeroLayout: Bool { page.id == 0 || page.id == 1 }
    private var usesTappablePremiumHero: Bool { page.id == 0 || page.id == 1 }

    var body: some View {
        GeometryReader { geo in
            let heroWidth = geo.size.width * heroWidthFraction(for: page)
            let standardHeroHeight = contentHeight * DiscoverHelpCarouselLayout.heroHeightFraction
            let premiumHeroHeight = contentHeight * premiumHeroHeightFraction(for: page)
            let heroHeight = usesPremiumHeroLayout ? premiumHeroHeight : standardHeroHeight
            let premiumHeroImageHeight = premiumHeroImageHeight(
                heroHeight: heroHeight,
                page: page
            )

            VStack(spacing: usesTappablePremiumHero ? 0 : DiscoverHelpCarouselLayout.sectionSpacing) {
                Group {
                    if usesTappablePremiumHero {
                        Button {
                            showPremiumHeroFullscreen = true
                        } label: {
                            DiscoverHelpHeroIllustration(
                                page: page,
                                preferredWidth: heroWidth,
                                preferredHeight: premiumHeroImageHeight,
                                languageCode: languageCode
                            )
                            .matchedTransitionSource(
                                id: premiumHeroZoomTransitionID(for: page),
                                in: premiumHeroZoomNamespace
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(premiumHeroAccessibilityLabel(for: page))
                        .accessibilityHint(
                            L10n.t(
                                "Opens a fullscreen zoomable view of the onboarding illustration",
                                languageCode: languageCode
                            )
                        )
                    } else {
                        DiscoverHelpHeroIllustration(
                            page: page,
                            preferredWidth: heroWidth,
                            preferredHeight: heroHeight,
                            languageCode: languageCode
                        )
                        .accessibilityHidden(true)
                    }
                }
                .padding(.top, usesPremiumHeroLayout ? premiumHeroTopInset(for: page) : 0)
                .frame(maxWidth: .infinity)

                if !page.heroCallouts.isEmpty {
                    DiscoverHelpHeroCalloutsRow(callouts: page.heroCallouts, languageCode: languageCode)
                        .padding(.top, 2)
                }

                if !usesPremiumHeroLayout {
                    DiscoverHelpFeatureBadge(
                        systemImage: page.systemImage,
                        accentColor: page.accentColor,
                        gradientColors: page.gradientColors
                    )
                }

                if isDiscoverWelcomePage {
                    discoverWelcomeCopySection
                } else if isDiscoverOnboardingPage {
                    discoverOnboardingCopySection
                } else {
                    featurePageCopySection
                }
            }
            .frame(width: geo.size.width, height: contentHeight, alignment: .top)
        }
        .padding(.horizontal, premiumHeroHorizontalInset(for: page))
        .fullScreenCover(isPresented: $showPremiumHeroFullscreen) {
            FanGeoZoomableImageFullscreenViewer(
                source: .asset(name: premiumHeroAssetName(for: page)),
                onDismiss: { showPremiumHeroFullscreen = false }
            )
            .navigationTransition(
                .zoom(
                    sourceID: premiumHeroZoomTransitionID(for: page),
                    in: premiumHeroZoomNamespace
                )
            )
        }
        .accessibilityElement(children: usesTappablePremiumHero ? .contain : .combine)
        .accessibilityLabel(discoverHelpCarouselAccessibilityLabel(for: page))
    }

    @ViewBuilder
    private var discoverWelcomeCopySection: some View {
        VStack(spacing: DiscoverHelpCarouselLayout.welcomeCopySpacing) {
            let welcomeLine = page.welcomeLine(languageCode: languageCode)
            let quickTour = page.primaryText(languageCode: languageCode)
            let tagline = page.tagline(languageCode: languageCode)
            let secondaryText = page.secondaryText(languageCode: languageCode)

            if !welcomeLine.isEmpty {
                Text(welcomeLine)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                if let personalizedDisplayName, !personalizedDisplayName.isEmpty {
                    Text(
                        String(
                            format: L10n.t("welcome_guide_personalized_greeting_format", languageCode: languageCode),
                            locale: Locale(identifier: languageCode),
                            personalizedDisplayName
                        )
                    )
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .padding(.top, -2)
                }
            }

            if !quickTour.isEmpty {
                Text(quickTour)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .multilineTextAlignment(.center)
            }

            if !tagline.isEmpty {
                Text(tagline)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 330)
            }

            if !secondaryText.isEmpty {
                Text(secondaryText)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320)
            }

            discoverWelcomeHighlightList
        }
        .padding(.horizontal, 8)
        .padding(.top, isDiscoverWelcomePage ? DiscoverHelpCarouselLayout.welcomeHeroToCopySpacing : 2)
    }

    private func heroWidthFraction(for page: DiscoverHelpCarouselPage) -> CGFloat {
        switch page.id {
        case 0:
            return DiscoverHelpCarouselLayout.welcomeHeroWidthFraction
        case 1:
            return DiscoverHelpCarouselLayout.discoverHeroWidthFraction
        default:
            return DiscoverHelpCarouselLayout.heroWidthFraction
        }
    }

    private func premiumHeroHeightFraction(for page: DiscoverHelpCarouselPage) -> CGFloat {
        switch page.id {
        case 0:
            return DiscoverHelpCarouselLayout.welcomeHeroHeightFraction
        case 1:
            return DiscoverHelpCarouselLayout.discoverHeroHeightFraction
        default:
            return DiscoverHelpCarouselLayout.discoverWelcomeHeroHeightFraction
        }
    }

    private func premiumHeroTopInset(for page: DiscoverHelpCarouselPage) -> CGFloat {
        switch page.id {
        case 0:
            return DiscoverHelpCarouselLayout.welcomeHeroTopInset
        case 1:
            return DiscoverHelpCarouselLayout.discoverHeroTopInset
        default:
            return DiscoverHelpCarouselLayout.discoverWelcomeHeroVerticalInset
        }
    }

    private func premiumHeroHorizontalInset(for page: DiscoverHelpCarouselPage) -> CGFloat {
        switch page.id {
        case 0:
            return DiscoverHelpCarouselLayout.welcomeHeroHorizontalInset
        case 1:
            return DiscoverHelpCarouselLayout.discoverHeroHorizontalInset
        default:
            return FGSpacing.lg
        }
    }

    private func premiumHeroImageHeight(
        heroHeight: CGFloat,
        page: DiscoverHelpCarouselPage
    ) -> CGFloat {
        let availableHeight = max(heroHeight - premiumHeroTopInset(for: page), 150)
        let maxHeight: CGFloat? = switch page.id {
        case 0:
            DiscoverHelpCarouselLayout.welcomeHeroMaxDisplayedHeight
        case 1:
            DiscoverHelpCarouselLayout.discoverHeroMaxDisplayedHeight
        default:
            nil
        }
        guard let maxHeight else { return availableHeight }
        return min(availableHeight, maxHeight)
    }

    private func premiumHeroZoomTransitionID(for page: DiscoverHelpCarouselPage) -> String {
        switch page.id {
        case 0:
            return DiscoverHelpCarouselLayout.welcomeHeroZoomTransitionID
        case 1:
            return DiscoverHelpCarouselLayout.discoverHeroZoomTransitionID
        default:
            return "onboarding-hero-\(page.id)"
        }
    }

    private func premiumHeroAssetName(for page: DiscoverHelpCarouselPage) -> String {
        switch page.id {
        case 0:
            return UIImage(named: "WelcomeOnboardingIllustration") != nil
                ? "WelcomeOnboardingIllustration"
                : "DiscoverOnboardingIllustration"
        case 1:
            return "DiscoverOnboardingIllustration"
        default:
            return ""
        }
    }

    private func premiumHeroAccessibilityLabel(for page: DiscoverHelpCarouselPage) -> String {
        switch page.id {
        case 0:
            return L10n.t("guide_welcome_hero_a11y", languageCode: languageCode)
        case 1:
            return L10n.t("guide_discover_hero_a11y", languageCode: languageCode)
        default:
            return page.title(languageCode: languageCode)
        }
    }

    @ViewBuilder
    private var discoverWelcomeHighlightList: some View {
        let bullets = page.bulletPoints(languageCode: languageCode)
        if !bullets.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(bullets.enumerated()), id: \.offset) { _, point in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.72 : 0.88))
                            .frame(width: 5, height: 5)
                            .padding(.top, 6)
                            .accessibilityHidden(true)
                        Text(point)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: 300, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 4)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var discoverOnboardingCopySection: some View {
        let title = page.title(languageCode: languageCode)
        let primaryText = page.primaryText(languageCode: languageCode)
        VStack(spacing: DiscoverHelpCarouselLayout.welcomeCopySpacing) {
            Text(title)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            if !primaryText.isEmpty {
                Text(primaryText)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320)
            }

            discoverWelcomeHighlightList
        }
        .padding(.horizontal, 8)
        .padding(.top, DiscoverHelpCarouselLayout.discoverHeroToCopySpacing)
    }

    @ViewBuilder
    private var featurePageCopySection: some View {
        let title = page.title(languageCode: languageCode)
        let primaryText = page.primaryText(languageCode: languageCode)
        let footerText = page.footerText(languageCode: languageCode)
        Text(title)
            .font(FGTypography.sectionTitle)
            .foregroundStyle(FGColor.primaryText(colorScheme))
            .accessibilityAddTraits(.isHeader)

        VStack(spacing: DiscoverHelpCarouselLayout.copySpacing) {
            if !primaryText.isEmpty {
                Text(primaryText)
                    .font(FGTypography.body.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            discoverHelpHighlightList

            if !footerText.isEmpty {
                Text(footerText)
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var discoverHelpHighlightList: some View {
        let bullets = page.bulletPoints(languageCode: languageCode)
        if !bullets.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(bullets.enumerated()), id: \.offset) { _, point in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(FGTypography.caption.weight(.bold))
                            .foregroundStyle(FGColor.accentGreen)
                            .accessibilityHidden(true)
                        Text(point)
                            .font(FGTypography.caption.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .accessibilityElement(children: .combine)
        }
    }

    private func discoverHelpCarouselAccessibilityLabel(for page: DiscoverHelpCarouselPage) -> String {
        var parts: [String] = []
        let welcomeLine = page.welcomeLine(languageCode: languageCode)
        if !welcomeLine.isEmpty {
            parts.append(welcomeLine)
        }
        if page.id == 0,
           let personalizedDisplayName,
           !personalizedDisplayName.isEmpty {
            parts.append(
                String(
                    format: L10n.t("welcome_guide_personalized_greeting_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    personalizedDisplayName
                )
            )
        }
        let quickTour = page.id == 0 ? page.primaryText(languageCode: languageCode) : ""
        if !quickTour.isEmpty {
            parts.append(quickTour)
        }
        let tagline = page.tagline(languageCode: languageCode)
        if !tagline.isEmpty {
            parts.append(tagline)
        }
        let title = page.title(languageCode: languageCode)
        if !title.isEmpty {
            parts.append(title)
        }
        let primaryText = page.id == 0 ? "" : page.primaryText(languageCode: languageCode)
        if !primaryText.isEmpty {
            parts.append(primaryText)
        }
        let secondaryText = page.secondaryText(languageCode: languageCode)
        if !secondaryText.isEmpty {
            parts.append(secondaryText)
        }
        let bullets = page.bulletPoints(languageCode: languageCode)
        if !bullets.isEmpty {
            parts.append(bullets.joined(separator: ". "))
        }
        let footerText = page.footerText(languageCode: languageCode)
        if !footerText.isEmpty {
            parts.append(footerText)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ". ")
    }
}

private struct DiscoverHelpFeatureBadge: View {
    let systemImage: String
    let accentColor: Color
    let gradientColors: [Color]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: gradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 44, height: 44)
                .shadow(color: accentColor.opacity(colorScheme == .dark ? 0.32 : 0.24), radius: 8, y: 3)

            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }
}

private struct DiscoverHelpHeroSoftEdgeMask: View {
    var body: some View {
        GeometryReader { _ in
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.11),
                    .init(color: .black, location: 0.89),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.76),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }
}

private struct DiscoverHelpHeroSoftEdgePresentationModifier: ViewModifier {
    let width: CGFloat
    let height: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: width, maxHeight: height)
            .compositingGroup()
            .mask {
                DiscoverHelpHeroSoftEdgeMask()
            }
            .frame(width: width, height: height, alignment: .center)
    }
}

private extension View {
    func discoverHelpHeroSoftEdgePresentation(width: CGFloat, height: CGFloat) -> some View {
        modifier(DiscoverHelpHeroSoftEdgePresentationModifier(width: width, height: height))
    }
}

private struct DiscoverHelpHeroIllustration: View {
    let page: DiscoverHelpCarouselPage
    var preferredWidth: CGFloat = 280
    var preferredHeight: CGFloat = 190
    var languageCode: String = L10n.defaultLanguageCode
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    var body: some View {
        if page.id == 0 || page.id == 1 {
            Group {
                switch page.id {
                case 0: welcomeHero
                case 1: discoverOnboardingHero
                default: EmptyView()
                }
            }
            .frame(width: preferredWidth, height: preferredHeight, alignment: .center)
            .frame(maxWidth: .infinity)
        } else {
            Group {
                switch page.id {
                case 2: liveHero
                case 3: calendarHero
                case 4: goingHero
                case 5: chatHero
                case 6: profileHero
                default: profileHero
                }
            }
            .discoverHelpHeroSoftEdgePresentation(width: preferredWidth, height: preferredHeight)
            .frame(maxWidth: .infinity)
        }
    }

    private func bundledHeroImage(named name: String, accessibilityLabel label: String) -> some View {
        Image(name)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: preferredWidth, maxHeight: preferredHeight)
            .accessibilityLabel(label)
    }

    private var welcomeHero: some View {
        Group {
            if UIImage(named: "WelcomeOnboardingIllustration") != nil {
                Image("WelcomeOnboardingIllustration")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: preferredWidth, maxHeight: preferredHeight)
            } else {
                Image("DiscoverOnboardingIllustration")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: preferredWidth, maxHeight: preferredHeight)
            }
        }
        .frame(maxWidth: preferredWidth, maxHeight: preferredHeight, alignment: .center)
        .clipShape(
            RoundedRectangle(
                cornerRadius: DiscoverHelpCarouselLayout.discoverWelcomeHeroCornerRadius,
                style: .continuous
            )
        )
        .accessibilityLabel(L10n.t("guide_welcome_hero_a11y", languageCode: languageCode))
    }

    private var discoverOnboardingHero: some View {
        Group {
            if UIImage(named: "DiscoverOnboardingIllustration") != nil {
                Image("DiscoverOnboardingIllustration")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: preferredWidth, maxHeight: preferredHeight)
            } else {
                Image(systemName: "map.fill")
                    .font(.system(size: 72, weight: .semibold))
                    .foregroundStyle(FGColor.accentGreen.opacity(0.85))
                    .frame(maxWidth: preferredWidth, maxHeight: preferredHeight)
            }
        }
        .frame(maxWidth: preferredWidth, maxHeight: preferredHeight, alignment: .center)
        .clipShape(
            RoundedRectangle(
                cornerRadius: DiscoverHelpCarouselLayout.discoverWelcomeHeroCornerRadius,
                style: .continuous
            )
        )
        .accessibilityLabel(L10n.t("guide_discover_hero_a11y", languageCode: languageCode))
    }

    private var liveHero: some View {
        bundledHeroImage(
            named: "LiveOnboardingIllustration",
            accessibilityLabel: L10n.t("guide_live_hero_a11y", languageCode: languageCode)
        )
    }

    @ViewBuilder
    private var goingHero: some View {
        if UIImage(named: "GoingOnboardingIllustration") != nil {
            bundledHeroImage(
                named: "GoingOnboardingIllustration",
                accessibilityLabel: L10n.t("guide_going_hero_a11y", languageCode: languageCode)
            )
        } else {
            goingProgrammaticHero
        }
    }

    private var goingProgrammaticHero: some View {
        let designWidth: CGFloat = 260
        let designHeight: CGFloat = 200
        let scale = min(preferredWidth / designWidth, preferredHeight / designHeight)

        return ZStack {
            Ellipse()
                .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.14 : 0.10))
                .frame(width: 240, height: 120)
                .blur(radius: 18)

            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white)
                .frame(width: 210, height: 156)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 10) {
                        goingEventRow(
                            symbol: "building.2.fill",
                            title: L10n.t("guide_going_demo_event_1", languageCode: languageCode),
                            detail: L10n.t("guide_going_demo_detail_1", languageCode: languageCode)
                        )
                        goingEventRow(
                            symbol: "figure.run",
                            title: L10n.t("guide_going_demo_event_2", languageCode: languageCode),
                            detail: L10n.t("guide_going_demo_detail_2", languageCode: languageCode)
                        )
                        goingEventRow(
                            symbol: "sportscourt.fill",
                            title: L10n.t("guide_going_demo_event_3", languageCode: languageCode),
                            detail: L10n.t("guide_going_demo_detail_3", languageCode: languageCode)
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.12), radius: 14, y: 7)

            Image(systemName: "heart.circle.fill")
                .font(.system(size: 28, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, page.accentColor)
                .offset(x: 84, y: 62)
        }
        .frame(width: designWidth, height: designHeight)
        .scaleEffect(scale)
    }

    private func goingEventRow(symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(page.accentColor.opacity(0.14))
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(page.accentColor)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text(detail)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
            Spacer(minLength: 0)
        }
    }

    private var calendarHero: some View {
        let designWidth: CGFloat = 260
        let designHeight: CGFloat = 200
        let scale = min(preferredWidth / designWidth, preferredHeight / designHeight)

        return ZStack {
            Ellipse()
                .fill(Color(red: 0.58, green: 0.42, blue: 0.94).opacity(colorScheme == .dark ? 0.14 : 0.10))
                .frame(width: 240, height: 120)
                .blur(radius: 18)

            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white)
                .frame(width: 190, height: 148)
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: page.gradientColors,
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 34)
                        .overlay {
                            HStack(spacing: 6) {
                                ForEach(0..<3, id: \.self) { _ in
                                    Circle()
                                        .fill(Color.white.opacity(0.85))
                                        .frame(width: 5, height: 5)
                                }
                            }
                        }
                }
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 10) {
                        calendarEventRow(
                            title: L10n.t("guide_calendar_demo_event_1", languageCode: languageCode),
                            detail: L10n.t("guide_calendar_demo_time_1", languageCode: languageCode)
                        )
                        calendarEventRow(
                            title: L10n.t("guide_calendar_demo_event_2", languageCode: languageCode),
                            detail: L10n.t("guide_calendar_demo_time_2", languageCode: languageCode)
                        )
                        calendarEventRow(
                            title: L10n.t("guide_calendar_demo_event_3", languageCode: languageCode),
                            detail: L10n.t("guide_calendar_demo_time_3", languageCode: languageCode)
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 44)
                }
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.12), radius: 14, y: 7)

            Image(systemName: "star.circle.fill")
                .font(.system(size: 28, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, page.accentColor)
                .offset(x: 78, y: 58)
        }
        .frame(width: designWidth, height: designHeight)
        .scaleEffect(scale)
    }

    private func calendarEventRow(title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(page.accentColor.opacity(0.85))
                .frame(width: 3, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text(detail)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
            Spacer(minLength: 0)
        }
    }

    private var chatHero: some View {
        bundledHeroImage(
            named: "ChatOnboardingIllustration",
            accessibilityLabel: L10n.t("guide_chat_hero_a11y", languageCode: languageCode)
        )
    }

    private var profileHero: some View {
        Group {
            if UIImage(named: "ProfileOnboardingIllustration") != nil {
                bundledHeroImage(
                    named: "ProfileOnboardingIllustration",
                    accessibilityLabel: L10n.t("guide_profile_hero_a11y", languageCode: languageCode)
                )
            } else {
                DiscoverHelpProfileOnboardingScreenshotHero(
                    preferredWidth: preferredWidth,
                    preferredHeight: preferredHeight,
                    languageCode: languageCode
                )
            }
        }
        .accessibilityLabel(L10n.t("guide_profile_hero_a11y", languageCode: languageCode))
    }
}

private struct DiscoverHelpFeatureHighlightRow: View {
    let highlight: DiscoverHelpFeatureHighlight
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(highlight.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.14))
                    .frame(width: 30, height: 30)
                Image(systemName: highlight.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(highlight.accentColor)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.t(highlight.titleKey))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text(L10n.t(highlight.detailKey))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct DiscoverHelpProTipCard: View {
    let title: String
    let bodyText: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("💡")
                .font(.system(size: 16))
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text(bodyText)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 330, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.14 : 0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.28 : 0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct DiscoverHelpHeroCalloutsRow: View {
    let callouts: [DiscoverHelpHeroCallout]
    var languageCode: String = L10n.defaultLanguageCode

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 4) {
            ForEach(callouts) { callout in
                HStack(spacing: 6) {
                    Text(callout.emoji)
                        .font(.system(size: 12))
                    Text(L10n.t(callout.labelKey, languageCode: languageCode))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct DiscoverHelpProfileOnboardingScreenshotHero: View {
    var preferredWidth: CGFloat
    var preferredHeight: CGFloat
    var languageCode: String = L10n.defaultLanguageCode

    @Environment(\.colorScheme) private var colorScheme

    private let designWidth: CGFloat = 268
    private let designHeight: CGFloat = 300

    var body: some View {
        let scale = min(preferredWidth / designWidth, preferredHeight / designHeight)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    FGColor.accentGreen.opacity(0.28),
                                    FGColor.accentBlue.opacity(0.22)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 54, height: 54)
                        .overlay {
                            Image(systemName: "person.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(FGColor.primaryText(colorScheme).opacity(0.82))
                        }

                    Text(L10n.t("guide_profile_demo_badge", languageCode: languageCode))
                        .font(.system(size: 7.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(FGColor.accentGreen))
                        .offset(x: 4, y: 4)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("guide_profile_demo_name", languageCode: languageCode))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text(L10n.t("guide_profile_demo_handle", languageCode: languageCode))
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                    Text(L10n.t("guide_profile_demo_subtitle", languageCode: languageCode))
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .lineLimit(2)
                }
            }

            HStack(spacing: 0) {
                profileIdentityMetric(
                    icon: "star.circle.fill",
                    title: L10n.t("rookie_fan", languageCode: languageCode),
                    subtitle: L10n.t("guide_profile_demo_xp", languageCode: languageCode),
                    tint: FGColor.accentGreen
                )
                profileIdentityDivider
                profileIdentityMetric(
                    icon: "sportscourt.fill",
                    title: L10n.t("guide_profile_demo_teams_metric", languageCode: languageCode),
                    subtitle: L10n.t("guide_profile_demo_primary_team", languageCode: languageCode),
                    tint: FGColor.accentBlue
                )
                profileIdentityDivider
                profileIdentityMetric(
                    icon: "shield.lefthalf.filled",
                    title: L10n.t("guide_profile_demo_reputation", languageCode: languageCode),
                    subtitle: L10n.t("guide_profile_demo_trusted_fan", languageCode: languageCode),
                    tint: FGColor.accentBlue
                )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(identityPanelFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(identityPanelBorder, lineWidth: 0.8)
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("favorite_teams", languageCode: languageCode).uppercased(with: Locale(identifier: languageCode)))
                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                    .foregroundStyle(FGColor.accentBlue)
                    .tracking(0.6)

                HStack(spacing: 8) {
                    profileTeamCard(title: "Lakers", colors: [Color(red: 0.36, green: 0.12, blue: 0.55), Color(red: 0.98, green: 0.76, blue: 0.18)])
                    profileTeamCard(title: "Jazz", colors: [Color(red: 0.02, green: 0.12, blue: 0.36), Color(red: 0.98, green: 0.36, blue: 0.16)])
                    profileTeamCard(title: "Real Madrid", colors: [Color.white, Color(red: 0.84, green: 0.72, blue: 0.42)], darkText: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("suggested_fans", languageCode: languageCode).uppercased(with: Locale(identifier: languageCode)))
                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                    .foregroundStyle(FGColor.accentBlue)
                    .tracking(0.6)

                HStack(spacing: 8) {
                    profileSuggestedFanCard(
                        name: L10n.t("guide_profile_demo_fan_1_name", languageCode: languageCode),
                        detail: L10n.t("guide_profile_demo_fan_1_detail", languageCode: languageCode)
                    )
                    profileSuggestedFanCard(
                        name: L10n.t("guide_profile_demo_fan_2_name", languageCode: languageCode),
                        detail: L10n.t("guide_profile_demo_fan_2_detail", languageCode: languageCode)
                    )
                }
            }
        }
        .padding(12)
        .frame(width: designWidth, alignment: .leading)
        .background(cardShell)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(cardBorder, lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.10), radius: 12, y: 6)
        .scaleEffect(scale)
        .frame(width: designWidth * scale, height: designHeight * scale, alignment: .top)
    }

    private var identityPanelFill: Color {
        colorScheme == .dark
            ? Color(red: 0.10, green: 0.14, blue: 0.20).opacity(0.92)
            : Color(red: 0.93, green: 0.95, blue: 0.99)
    }

    private var identityPanelBorder: Color {
        colorScheme == .dark
            ? FGColor.divider(colorScheme).opacity(0.65)
            : Color(red: 0.84, green: 0.88, blue: 0.95)
    }

    private var cardShell: some ShapeStyle {
        colorScheme == .dark
            ? AnyShapeStyle(Color(red: 0.08, green: 0.10, blue: 0.14))
            : AnyShapeStyle(Color.white)
    }

    private var cardBorder: Color {
        FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.55 : 0.85)
    }

    private var profileIdentityDivider: some View {
        Rectangle()
            .fill(FGColor.divider(colorScheme).opacity(0.75))
            .frame(width: 1)
            .padding(.vertical, 4)
    }

    private func profileIdentityMetric(icon: String, title: String, subtitle: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Text(subtitle)
                .font(.system(size: 7.5, weight: .medium, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private func profileTeamCard(title: String, colors: [Color], darkText: Bool = false) -> some View {
        Text(title)
            .font(.system(size: 8.5, weight: .bold, design: .rounded))
            .foregroundStyle(darkText ? FGColor.primaryText(colorScheme) : .white)
            .lineLimit(2)
            .minimumScaleFactor(0.75)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .bottomLeading)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: colors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .frame(maxWidth: .infinity)
    }

    private func profileSuggestedFanCard(name: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(FGColor.accentBlue.opacity(0.16))
                    .frame(width: 22, height: 22)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(FGColor.accentBlue)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text(detail)
                        .font(.system(size: 7.5, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
            }

            Text(L10n.t("Add Friend", languageCode: languageCode))
                .font(.system(size: 7.5, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.accentGreen)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.16 : 0.11))
                )
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(SettingsPremiumChrome.cardFill(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(SettingsPremiumChrome.cardStroke(colorScheme), lineWidth: 0.6)
        )
    }
}

private struct DiscoverIntegratedLocationButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.68), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                guard pressed else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
    }
}

private struct DiscoverModeSegmentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: configuration.isPressed)
    }
}

private extension View {
    func discoverLightGlassCard(
        cornerRadius: CGFloat = 22,
        style: DiscoverGlassChromeStyle = .overlay
    ) -> some View {
        modifier(DiscoverLightGlassCardModifier(cornerRadius: cornerRadius, style: style))
    }

    func discoverFloatingMapCircleButton(fill: AnyShapeStyle = AnyShapeStyle(Color.white)) -> some View {
        modifier(DiscoverFloatingMapCircleButtonModifier(fill: fill))
    }
}
