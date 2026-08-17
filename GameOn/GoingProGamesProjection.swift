import Foundation

/// Compact Going → Pro Games filter. Chips are the only Pro Games filter UI.
enum GoingProGamesFilter: String, CaseIterable, Hashable, Sendable {
    case all
    case saved
    case favoriteTeams

    var titleKey: String {
        switch self {
        case .all: return "going_play_filter_all"
        case .saved: return "Saved"
        case .favoriteTeams: return "Favorite Teams"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "trophy.fill"
        case .saved: return "bookmark.fill"
        case .favoriteTeams: return "heart.fill"
        }
    }
}

/// One professional game in Going → Pro Games. Saved and favorite-team reasons
/// can both be true; the game still renders once.
struct GoingProGameItem: Identifiable, Equatable {
    /// Canonical professional game identity (`SavedProGame.stableKey`).
    var id: String { game.stableKey }
    let game: SavedProGame
    let isSaved: Bool
    let involvesFavoriteTeam: Bool
    let favoriteTeamName: String?
    let favoriteAlertItem: FavoriteTeamProGame?
}

enum GoingProGamesProjection {
    struct FilterCounts: Equatable {
        var all: Int
        var saved: Int
        var favoriteTeams: Int
    }

    /// Saved ∪ Favorite Team games, deduped by `stableKey`.
    static func unified(
        saved: [SavedProGame],
        favorite: [FavoriteTeamProGame]
    ) -> [GoingProGameItem] {
        var favoriteByKey: [String: FavoriteTeamProGame] = [:]
        favoriteByKey.reserveCapacity(favorite.count)
        for item in favorite {
            let key = item.game.stableKey
            if favoriteByKey[key] == nil {
                favoriteByKey[key] = item
            }
        }

        var seen = Set<String>()
        var items: [GoingProGameItem] = []
        items.reserveCapacity(saved.count + favorite.count)

        for game in saved {
            let key = game.stableKey
            guard seen.insert(key).inserted else { continue }
            let favoriteHit = favoriteByKey[key]
            items.append(
                GoingProGameItem(
                    game: game,
                    isSaved: true,
                    involvesFavoriteTeam: favoriteHit != nil,
                    favoriteTeamName: favoriteHit?.favoriteTeamName,
                    favoriteAlertItem: favoriteHit
                )
            )
        }

        for item in favorite {
            let key = item.game.stableKey
            guard seen.insert(key).inserted else { continue }
            items.append(
                GoingProGameItem(
                    game: item.game,
                    isSaved: false,
                    involvesFavoriteTeam: true,
                    favoriteTeamName: item.favoriteTeamName,
                    favoriteAlertItem: item
                )
            )
        }

        return items.sorted { lhs, rhs in
            SavedProGame.displaySort(lhs.game, rhs.game)
        }
    }

    static func filtered(
        _ items: [GoingProGameItem],
        filter: GoingProGamesFilter
    ) -> [GoingProGameItem] {
        switch filter {
        case .all:
            return items
        case .saved:
            return items.filter(\.isSaved)
        case .favoriteTeams:
            return items.filter(\.involvesFavoriteTeam)
        }
    }

    static func filterCounts(_ items: [GoingProGameItem]) -> FilterCounts {
        FilterCounts(
            all: items.count,
            saved: items.filter(\.isSaved).count,
            favoriteTeams: items.filter(\.involvesFavoriteTeam).count
        )
    }

    static func matchupTitle(for game: SavedProGame) -> String {
        let away = ProGameTeamScoreIdentity.cleanTeamName(game.awayTeam)
        let home = ProGameTeamScoreIdentity.cleanTeamName(game.homeTeam)
        if away.isEmpty { return home }
        if home.isEmpty { return away }
        return "\(away) \(matchupSeparator(for: game.liveSportVisualType)) \(home)"
    }

    static func matchupSeparator(for sport: LiveSportVisualType) -> String {
        switch sport {
        case .basketball, .nfl, .hockey, .baseball:
            return "@"
        default:
            return "vs"
        }
    }

    static func statusTimeLine(
        for game: SavedProGame,
        languageCode: String,
        timeZoneOption: FanGeoTimeZonePreference,
        now: Date = Date()
    ) -> String {
        if game.matchStatus == .halfTime, !game.isFinal {
            return L10n.t("Halftime", languageCode: languageCode)
        }
        if game.matchStatus == .live, !game.isFinal {
            let live = L10n.t("LIVE", languageCode: languageCode)
            let clock = liveClockText(for: game)
            if let clock, !clock.isEmpty {
                return "\(live) · \(clock)"
            }
            return live
        }
        if game.isFinal {
            return L10n.t("FINAL", languageCode: languageCode).uppercased()
        }
        let day = compactDayLabel(for: game.startTime, languageCode: languageCode, now: now)
        let time = CompactGameTimeFormatter.timeWithZone(
            for: game.startTime,
            timeZoneOption: timeZoneOption
        )
        return "\(day) · \(time)"
    }

    static func compactDayLabel(
        for date: Date,
        languageCode: String,
        now: Date = Date()
    ) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return L10n.t("Today", languageCode: languageCode)
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return L10n.t("Tomorrow", languageCode: languageCode)
        }
        let locale = Locale(identifier: L10n.normalizedLanguageCode(languageCode))
        return date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted)
                .weekday(.abbreviated)
                .locale(locale)
        )
    }

    static func locationLine(
        for game: SavedProGame,
        liveMatches: [LiveMatch]
    ) -> String {
        guard let match = liveMatches.first(where: { SavedProGame.stableKey(for: $0) == game.stableKey }) else {
            return ""
        }
        let resolved = LiveMatchPlayedLocationPresentation.resolve(
            venueName: match.venueName,
            venueCity: match.venueCity,
            leagueCountry: match.leagueCountry,
            coordinate: match.venueCoordinate,
            localizedCountryName: nil
        )
        guard let resolved else { return "" }
        let parts = [resolved.primaryTitle, resolved.localityLine]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }

    static func leagueLine(for game: SavedProGame) -> String {
        let sport = AppSportCatalog.displayLabel(forSportToken: game.sport)
        let league = game.league.trimmingCharacters(in: .whitespacesAndNewlines)
        if sport.isEmpty { return league }
        if league.isEmpty { return sport }
        if sport.caseInsensitiveCompare(league) == .orderedSame { return league }
        return "\(sport) · \(league)"
    }

    /// Provider clock/minute for the LIVE scoreboard. Returns nil when the payload
    /// is empty or is only a status word (`LIVE`, `HT`, `FT`, …).
    static func liveClockText(for game: SavedProGame) -> String? {
        if game.liveSportVisualType == .soccer,
           let minute = game.minute,
           minute > 0 {
            return "\(minute)'"
        }
        let clock = game.liveClockText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !clock.isEmpty else { return nil }
        let normalized = LiveMatchFilters.normalizedSearchText(clock)
        if ["live", "ht", "ft", "final", "scheduled", "not started"].contains(normalized) {
            return nil
        }
        return clock
    }
}

/// Presentation-only decisions for the My Sports → Pro Games LIVE / HT card.
/// Scoring, alerts, favorites, and prediction lock logic stay in their existing owners.
struct GoingProLiveCardPresentation: Equatable {
    enum PrimaryStatus: Equatable {
        case live
        case halfTime
    }

    enum ContextChip: Equatable {
        case sport(emoji: String, label: String)
        case favoriteTeam
        case liveAlertsOn
        case liveAlertsOff
    }

    let primaryStatus: PrimaryStatus?
    let usesLargeLiveTreatment: Bool
    let usesPremiumActiveGameCard: Bool
    let textualLiveStatusCount: Int
    let textualHalftimeStatusCount: Int
    /// Compact Scheduled / Final cards used to squeeze tiny away/@/home logos into the title row.
    /// Matchup artwork belongs only in the scoreboard / body matchup below.
    let showsTitleAreaTeamLogos: Bool
    let showsTrailingLiveStatusChip: Bool
    let showsOverlayLiveTextBadge: Bool
    let showsMainScoreboardTeamLogos: Bool
    let showsBothTeamNames: Bool
    let scoreRenderCount: Int
    let clockText: String?
    let matchupTitle: String
    let awayTeamName: String
    let homeTeamName: String
    let awayScore: Int
    let homeScore: Int
    let contextChips: [ContextChip]
    let accessibilityLabel: String

    var showsFavoriteTeamChip: Bool {
        contextChips.contains { if case .favoriteTeam = $0 { return true }; return false }
    }

    var showsLiveAlertsOnChip: Bool {
        contextChips.contains { if case .liveAlertsOn = $0 { return true }; return false }
    }

    var showsLiveAlertsOffChip: Bool {
        contextChips.contains { if case .liveAlertsOff = $0 { return true }; return false }
    }

    static func primaryStatus(for game: SavedProGame) -> PrimaryStatus? {
        guard !game.isFinal else { return nil }
        switch game.matchStatus {
        case .live:
            return .live
        case .halfTime:
            return .halfTime
        case .fullTime, .scheduled:
            return nil
        }
    }

    /// LIVE and HT share one premium active-game card. Scheduled / Final stay compact.
    static func usesPremiumActiveGameCard(for game: SavedProGame) -> Bool {
        primaryStatus(for: game) != nil
    }

    static func usesLargeLiveTreatment(for game: SavedProGame) -> Bool {
        usesPremiumActiveGameCard(for: game)
    }

    static func make(
        game: SavedProGame,
        involvesFavoriteTeam: Bool,
        liveAlertsEnabled: Bool?,
        languageCode: String
    ) -> GoingProLiveCardPresentation {
        let status = primaryStatus(for: game)
        let isPremium = status != nil
        let awayName = ProGameTeamScoreIdentity.cleanTeamName(game.awayTeam)
        let homeName = ProGameTeamScoreIdentity.cleanTeamName(game.homeTeam)
        let clock: String?
        switch status {
        case .live:
            clock = GoingProGamesProjection.liveClockText(for: game)
        case .halfTime:
            clock = L10n.t("Halftime", languageCode: languageCode)
        case nil:
            clock = nil
        }
        let chips: [ContextChip] = isPremium
            ? liveContextChips(
                game: game,
                involvesFavoriteTeam: involvesFavoriteTeam,
                liveAlertsEnabled: liveAlertsEnabled
            )
            : []

        return GoingProLiveCardPresentation(
            primaryStatus: status,
            usesLargeLiveTreatment: isPremium,
            usesPremiumActiveGameCard: isPremium,
            textualLiveStatusCount: status == .live ? 1 : 0,
            textualHalftimeStatusCount: status == .halfTime ? 1 : 0,
            showsTitleAreaTeamLogos: false,
            showsTrailingLiveStatusChip: !isPremium,
            showsOverlayLiveTextBadge: false,
            showsMainScoreboardTeamLogos: true,
            showsBothTeamNames: !awayName.isEmpty && !homeName.isEmpty,
            scoreRenderCount: (isPremium || game.isFinal || game.matchStatus.isHappeningNow) ? 1 : 0,
            clockText: clock,
            matchupTitle: GoingProGamesProjection.matchupTitle(for: game),
            awayTeamName: awayName,
            homeTeamName: homeName,
            awayScore: game.scoreAway,
            homeScore: game.scoreHome,
            contextChips: chips,
            accessibilityLabel: accessibilitySpokenSummary(
                status: status,
                matchupTitle: GoingProGamesProjection.matchupTitle(for: game),
                awayName: awayName,
                homeName: homeName,
                awayScore: game.scoreAway,
                homeScore: game.scoreHome,
                clockText: clock,
                soccerMinute: status == .live && game.liveSportVisualType == .soccer ? game.minute : nil,
                languageCode: languageCode
            )
        )
    }

    private static func liveContextChips(
        game: SavedProGame,
        involvesFavoriteTeam: Bool,
        liveAlertsEnabled: Bool?
    ) -> [ContextChip] {
        var chips: [ContextChip] = []
        let sportLabel = liveSportChipLabel(for: game)
        if !sportLabel.isEmpty {
            chips.append(
                .sport(
                    emoji: game.liveSportVisualType.proGameLeagueChipVisual.emoji,
                    label: sportLabel
                )
            )
        }
        if involvesFavoriteTeam {
            chips.append(.favoriteTeam)
        }
        if let liveAlertsEnabled {
            chips.append(liveAlertsEnabled ? .liveAlertsOn : .liveAlertsOff)
        }
        return chips
    }

    static func liveSportChipLabel(for game: SavedProGame) -> String {
        let storedEnglish = AppSportCatalog.catalogEnglishLabel(forSportToken: game.sport)
        if isShortSportFamilyLabel(storedEnglish) {
            let catalog = AppSportCatalog.displayLabel(forSportToken: game.sport)
            if !catalog.isEmpty { return catalog }
        }
        let familyToken = sportFamilyToken(for: game)
        let familyLabel = AppSportCatalog.displayLabel(forSportToken: familyToken)
        if !familyLabel.isEmpty { return familyLabel }
        let visual = game.liveSportVisualType.displayLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return visual
    }

    private static func isShortSportFamilyLabel(_ english: String) -> Bool {
        let known = [
            "Soccer",
            "Basketball",
            "Hockey",
            "Baseball",
            "Football",
            "Tennis",
            "Golf",
            "Badminton"
        ]
        return known.contains { $0.caseInsensitiveCompare(english) == .orderedSame }
    }

    /// Sport family for the premium chip (`Soccer`), never a classification like "Club Football".
    private static func sportFamilyToken(for game: SavedProGame) -> String {
        switch game.liveSportVisualType {
        case .soccer:
            return "Soccer"
        case .basketball:
            return "Basketball"
        case .hockey:
            return "Hockey"
        case .baseball:
            return "Baseball"
        case .nfl:
            return "American Football"
        case .tennis:
            return "Tennis"
        case .badminton:
            return "Badminton"
        case .golf:
            return "Golf"
        case .formula1:
            return "Formula 1"
        case .breakdance:
            return "Break Dance"
        case .ballet:
            return "Ballet"
        case .other:
            let text = LiveMatchFilters.normalizedSearchText("\(game.sport) \(game.league)")
            if text.contains("american football") || text.contains("nfl") {
                return "American Football"
            }
            if text.contains("soccer")
                || text.contains("football")
                || text.contains("fifa")
                || text.contains("uefa") {
                return "Soccer"
            }
            return game.sport
        }
    }

    private static func accessibilitySpokenSummary(
        status: PrimaryStatus?,
        matchupTitle: String,
        awayName: String,
        homeName: String,
        awayScore: Int,
        homeScore: Int,
        clockText: String?,
        soccerMinute: Int?,
        languageCode: String
    ) -> String {
        guard let status else { return matchupTitle }

        let statusWord: String
        switch status {
        case .live:
            statusWord = L10n.t("LIVE", languageCode: languageCode)
        case .halfTime:
            statusWord = L10n.t("Halftime", languageCode: languageCode)
        }
        let scorePhrase = "\(awayName) \(awayScore), \(homeName) \(homeScore)"
        let clockPhrase: String?
        switch status {
        case .live:
            if let soccerMinute, soccerMinute > 0 {
                clockPhrase = spokenSoccerMinute(soccerMinute, languageCode: languageCode)
            } else {
                let clock = clockText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                clockPhrase = clock.isEmpty ? nil : clock
            }
        case .halfTime:
            clockPhrase = nil
        }

        if let clockPhrase {
            return "\(statusWord). \(scorePhrase), \(clockPhrase)"
        }
        return "\(statusWord). \(scorePhrase)"
    }

    /// Type-safe "minute 78" copy. Never `String(format:)` — locale catalogs previously
    /// used `%@ minute %@` while the caller passed a single `Int`, which crashes Foundation.
    private static func spokenSoccerMinute(_ minute: Int, languageCode: String) -> String {
        let raw = L10n.t("going_pro_live_minute_a11y_format", languageCode: languageCode)
        let word = raw
            .replacingOccurrences(of: "%lld", with: "")
            .replacingOccurrences(of: "%ld", with: "")
            .replacingOccurrences(of: "%d", with: "")
            .replacingOccurrences(of: "%@", with: "")
            .replacingOccurrences(of: "%%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let label = word.isEmpty ? "minute" : word
        return "\(label) \(minute)"
    }
}
