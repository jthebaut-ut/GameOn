import Foundation

/// Presentation-only Discover search placeholder examples.
/// Builds a compact in-memory list from already-loaded context — never searches, networks, or geocodes.
enum DiscoverSearchPlaceholderProvider {
    enum Category: Int, Sendable, Equatable {
        case team
        case competition
        case city
        case fan
        case place
        case sport
    }

    struct Example: Equatable, Sendable {
        let category: Category
        /// Localized or proper-noun term inserted into `discover_search_placeholder_example_format`.
        let term: String
    }

    struct Context: Equatable, Sendable {
        var selectedSport: String
        var isWatchMode: Bool
        var isPlayGames: Bool
        var isPlayPlaces: Bool
        var favoriteTeamNames: [String]
        var homeCity: String?
        var languageCode: String
        /// Stable per Discover appearance so shuffle differs between visits without re-shuffling in `body`.
        var appearanceSeed: UInt64
    }

    /// Builds 5–8 examples once per rotation session. Deterministic for a given context + seed.
    static func makeRotationList(context: Context) -> [Example] {
        let languageCode = L10n.normalizedLanguageCode(context.languageCode)
        let sport = normalizedSport(context.selectedSport)

        var teams = teamCandidates(sport: sport)
        let competitions = competitionCandidates(sport: sport)
        let cities = cityCandidates(sport: sport, homeCity: context.homeCity)
        let fans = fanCandidates(languageCode: languageCode)
        let places = placeCandidates(
            sport: sport,
            isPlayGames: context.isPlayGames,
            isPlayPlaces: context.isPlayPlaces,
            languageCode: languageCode
        )
        let sports = sportCandidates(
            sport: sport,
            isPlayGames: context.isPlayGames,
            isPlayPlaces: context.isPlayPlaces,
            languageCode: languageCode
        )

        // Prefer followed teams already resolved in memory (max 2).
        let favorites = context.favoriteTeamNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(2)
        for name in favorites.reversed() {
            teams.insert(Example(category: .team, term: name), at: 0)
        }

        // Mode prioritization: reorder bucket pick sequence.
        let bucketOrder: [[Example]]
        if context.isPlayPlaces {
            bucketOrder = [places, cities, sports, fans, teams, competitions]
        } else if context.isPlayGames {
            bucketOrder = [sports, places, cities, fans, teams, competitions]
        } else if context.isWatchMode {
            bucketOrder = [places, teams, competitions, cities, fans, sports]
        } else {
            bucketOrder = [teams, competitions, cities, fans, places, sports]
        }

        var picked: [Example] = []
        var seenTerms = Set<String>()
        var cursor = 0
        let targetCount = 7
        while picked.count < targetCount {
            var addedThisPass = false
            for bucket in bucketOrder {
                guard picked.count < targetCount else { break }
                guard cursor < bucket.count else { continue }
                let candidate = bucket[cursor]
                let key = normalizeKey(candidate.term)
                guard !key.isEmpty, !seenTerms.contains(key) else { continue }
                if let last = picked.last, last.category == candidate.category {
                    // Avoid same category twice in a row when alternatives remain.
                    let hasAlt = bucketOrder.contains { altBucket in
                        altBucket.contains { other in
                            other.category != candidate.category
                                && !seenTerms.contains(normalizeKey(other.term))
                        }
                    }
                    if hasAlt { continue }
                }
                seenTerms.insert(key)
                picked.append(candidate)
                addedThisPass = true
            }
            cursor += 1
            if !addedThisPass, cursor > 8 { break }
        }

        // One seeded shuffle for variation without render-time randomness.
        return seededShuffle(picked, seed: context.appearanceSeed)
    }

    static func displayText(for example: Example, languageCode: String) -> String {
        let code = L10n.normalizedLanguageCode(languageCode)
        return String(
            format: L10n.t("discover_search_placeholder_example_format", languageCode: code),
            locale: Locale(identifier: code),
            example.term
        )
    }

    // MARK: - Candidates (catalog / MapKit / fan / sport — verified searchable)

    private static func teamCandidates(sport: String) -> [Example] {
        switch sport {
        case "soccer":
            return [
                Example(category: .team, term: "Real Madrid"),
                Example(category: .team, term: "France"),
                Example(category: .team, term: "Manchester United")
            ]
        case "basketball":
            return [
                Example(category: .team, term: "Boston Celtics"),
                Example(category: .team, term: "Los Angeles Lakers")
            ]
        case "football":
            return [
                Example(category: .team, term: "Kansas City Chiefs"),
                Example(category: .team, term: "Dallas Cowboys")
            ]
        case "hockey":
            return [
                Example(category: .team, term: "Canada"),
                Example(category: .team, term: "Sweden")
            ]
        case "baseball":
            return [
                Example(category: .team, term: "New York Yankees"),
                Example(category: .team, term: "Boston Red Sox")
            ]
        default:
            return [
                Example(category: .team, term: "Real Madrid"),
                Example(category: .team, term: "Boston Celtics"),
                Example(category: .team, term: "France"),
                Example(category: .team, term: "New York Yankees")
            ]
        }
    }

    private static func competitionCandidates(sport: String) -> [Example] {
        switch sport {
        case "soccer":
            return [
                Example(category: .competition, term: "Champions League"),
                Example(category: .competition, term: "World Cup")
            ]
        case "basketball":
            return [Example(category: .competition, term: "NBA Finals")]
        case "football":
            return [Example(category: .competition, term: "Super Bowl")]
        case "hockey":
            return [Example(category: .competition, term: "Stanley Cup")]
        case "baseball":
            return [Example(category: .competition, term: "World Series")]
        default:
            return [
                Example(category: .competition, term: "NBA Finals"),
                Example(category: .competition, term: "Champions League"),
                Example(category: .competition, term: "World Cup"),
                Example(category: .competition, term: "Super Bowl")
            ]
        }
    }

    private static func cityCandidates(sport: String, homeCity: String?) -> [Example] {
        var cities: [Example] = []
        if let home = homeCity?.trimmingCharacters(in: .whitespacesAndNewlines), home.count >= 2 {
            cities.append(Example(category: .city, term: home))
        }
        switch sport {
        case "soccer":
            cities.append(contentsOf: [
                Example(category: .city, term: "Madrid"),
                Example(category: .city, term: "London"),
                Example(category: .city, term: "Miami")
            ])
        case "basketball":
            cities.append(contentsOf: [
                Example(category: .city, term: "Boston"),
                Example(category: .city, term: "Miami")
            ])
        case "football":
            cities.append(contentsOf: [
                Example(category: .city, term: "Kansas City"),
                Example(category: .city, term: "Miami")
            ])
        case "hockey":
            cities.append(contentsOf: [
                Example(category: .city, term: "Toronto"),
                Example(category: .city, term: "Boston")
            ])
        default:
            cities.append(contentsOf: [
                Example(category: .city, term: "Boston"),
                Example(category: .city, term: "Madrid"),
                Example(category: .city, term: "Miami"),
                Example(category: .city, term: "London")
            ])
        }
        return cities
    }

    private static func fanCandidates(languageCode: String) -> [Example] {
        let code = L10n.normalizedLanguageCode(languageCode)
        return [
            Example(category: .fan, term: L10n.t("discover_search_placeholder_fan_john", languageCode: code)),
            Example(category: .fan, term: L10n.t("discover_search_placeholder_fan_maria", languageCode: code)),
            Example(category: .fan, term: L10n.t("discover_search_placeholder_fan_alex", languageCode: code))
        ]
    }

    private static func placeCandidates(
        sport: String,
        isPlayGames: Bool,
        isPlayPlaces: Bool,
        languageCode: String
    ) -> [Example] {
        let code = L10n.normalizedLanguageCode(languageCode)
        if isPlayPlaces || isPlayGames {
            switch sport {
            case "basketball":
                return [
                    Example(category: .place, term: L10n.t("discover_search_placeholder_example_basketball_courts", languageCode: code)),
                    Example(category: .place, term: L10n.t("discover_search_placeholder_example_gyms", languageCode: code)),
                    Example(category: .place, term: L10n.t("discover_search_placeholder_example_parks", languageCode: code))
                ]
            case "soccer":
                return [
                    Example(category: .place, term: L10n.t("discover_search_placeholder_example_soccer_fields", languageCode: code)),
                    Example(category: .place, term: L10n.t("discover_search_placeholder_example_parks", languageCode: code)),
                    Example(category: .place, term: L10n.t("discover_search_placeholder_example_gyms", languageCode: code))
                ]
            case "football":
                return [
                    Example(category: .place, term: L10n.t("discover_search_placeholder_example_parks", languageCode: code)),
                    Example(category: .place, term: L10n.t("discover_search_placeholder_example_gyms", languageCode: code))
                ]
            case "hockey":
                return [
                    Example(category: .place, term: L10n.t("discover_search_placeholder_example_gyms", languageCode: code)),
                    Example(category: .place, term: L10n.t("discover_search_placeholder_example_parks", languageCode: code))
                ]
            default:
                return [
                    Example(category: .place, term: L10n.t("discover_search_placeholder_example_parks", languageCode: code)),
                    Example(category: .place, term: L10n.t("discover_search_placeholder_example_gyms", languageCode: code)),
                    Example(category: .place, term: L10n.t("discover_search_placeholder_example_basketball_courts", languageCode: code)),
                    Example(category: .place, term: L10n.t("discover_search_placeholder_example_soccer_fields", languageCode: code))
                ]
            }
        }

        // Watch (and default): MapKit / venue-name friendly place queries.
        switch sport {
        case "soccer":
            return [
                Example(category: .place, term: L10n.t("discover_search_placeholder_example_soccer_bars", languageCode: code)),
                Example(category: .place, term: L10n.t("discover_search_placeholder_example_sports_bars", languageCode: code))
            ]
        case "basketball":
            return [
                Example(category: .place, term: L10n.t("discover_search_placeholder_example_sports_bars", languageCode: code))
            ]
        case "hockey":
            return [
                Example(category: .place, term: L10n.t("discover_search_placeholder_example_hockey_bars", languageCode: code)),
                Example(category: .place, term: L10n.t("discover_search_placeholder_example_sports_bars", languageCode: code))
            ]
        case "football":
            return [
                Example(category: .place, term: L10n.t("discover_search_placeholder_example_sports_bars", languageCode: code))
            ]
        default:
            return [
                Example(category: .place, term: L10n.t("discover_search_placeholder_example_sports_bars", languageCode: code)),
                Example(category: .place, term: L10n.t("discover_search_placeholder_example_soccer_bars", languageCode: code))
            ]
        }
    }

    private static func sportCandidates(
        sport: String,
        isPlayGames: Bool,
        isPlayPlaces: Bool,
        languageCode: String
    ) -> [Example] {
        _ = languageCode
        guard isPlayGames || isPlayPlaces || sport == "all" else {
            return []
        }
        // English sport tokens match Discover venue-event / pickup sport fields.
        switch sport {
        case "soccer":
            return [Example(category: .sport, term: "Soccer")]
        case "basketball":
            return [Example(category: .sport, term: "Basketball")]
        case "football":
            return [Example(category: .sport, term: "Football")]
        case "hockey":
            return [Example(category: .sport, term: "Hockey")]
        default:
            return [
                Example(category: .sport, term: "Soccer"),
                Example(category: .sport, term: "Basketball")
            ]
        }
    }

    private static func normalizedSport(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.isEmpty || s == "all" || s == "all sports" { return "all" }
        if s.contains("soccer") { return "soccer" }
        if s == "football" || s == "nfl" || s.contains("american football") { return "football" }
        if s.contains("basket") { return "basketball" }
        if s.contains("hockey") { return "hockey" }
        if s.contains("baseball") { return "baseball" }
        return s
    }

    private static func normalizeKey(_ term: String) -> String {
        term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func seededShuffle(_ input: [Example], seed: UInt64) -> [Example] {
        guard input.count > 1 else { return input }
        var result = input
        var state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        for i in stride(from: result.count - 1, through: 1, by: -1) {
            state = state &* 6364136223846793005 &+ 1
            let j = Int(state % UInt64(i + 1))
            result.swapAt(i, j)
        }
        // Avoid identical first item as last when possible (consecutive across wrap).
        if result.count > 2, result.first?.category == result.last?.category {
            result.swapAt(0, 1)
        }
        return result
    }
}
