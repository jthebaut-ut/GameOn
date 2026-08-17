import Foundation

/// Reusable sport/activity subtype catalog (Cycling, Electric Scooter, Inline Skating, …).
///
/// Persisted separately from `sport` as `pickup_games.sport_subtype`.
/// Top-level Discover chips stay on `sport`; subtypes never become their own sports.
nonisolated enum SportSubtypeCatalog {

    struct Subtype: Equatable, Hashable, Sendable, Identifiable {
        let id: String
        let labelKey: String
        let searchAliases: [String]
        var systemImage: String

        init(
            id: String,
            labelKey: String,
            searchAliases: [String] = [],
            systemImage: String = "circle"
        ) {
            self.id = id
            self.labelKey = labelKey
            self.searchAliases = searchAliases
            self.systemImage = systemImage
        }
    }

    enum Family: String, Equatable, CaseIterable, Sendable {
        case cycling
        case electricScooter
        case inlineSkating
    }

    // MARK: - Families

    static func family(forSport sport: String) -> Family? {
        let token = AppSportCatalog.canonicalFormPickerToken(for: sport)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let label = AppSportCatalog.catalogEnglishLabel(forSportToken: sport)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let hay = "\(token) \(label)"

        if matchesAny(hay, ["electric scooter", "e-scooter", "escooter", "e scooter"]) {
            return .electricScooter
        }
        if matchesAny(hay, ["inline skat", "rollerblad", "roller blad", "rollerblade"]) {
            return .inlineSkating
        }
        if matchesAny(hay, ["cycling", "biking", "bicycle"]) {
            return .cycling
        }
        return nil
    }

    static func hasSubtypes(forSport sport: String) -> Bool {
        family(forSport: sport) != nil
    }

    static func subtypes(forSport sport: String) -> [Subtype] {
        guard let family = family(forSport: sport) else { return [] }
        return subtypes(for: family)
    }

    static func subtypes(for family: Family) -> [Subtype] {
        switch family {
        case .cycling:
            return [
                Subtype(
                    id: "road_cycling",
                    labelKey: "sport_subtype_road_cycling",
                    searchAliases: ["road cycling", "road bike", "road biking", "roadbike"],
                    systemImage: "bicycle"
                ),
                Subtype(
                    id: "mountain_biking",
                    labelKey: "sport_subtype_mountain_biking",
                    searchAliases: [
                        "mountain biking", "mountain bike", "mtb", "mountainbike",
                        "mountain bike ride"
                    ],
                    systemImage: "bicycle"
                ),
                Subtype(
                    id: "gravel",
                    labelKey: "sport_subtype_gravel",
                    searchAliases: ["gravel", "gravel bike", "gravel cycling", "gravel biking"],
                    systemImage: "bicycle"
                ),
                Subtype(
                    id: "bmx",
                    labelKey: "sport_subtype_bmx",
                    searchAliases: ["bmx", "bmx bike"],
                    systemImage: "bicycle"
                ),
                Subtype(
                    id: "e_bike",
                    labelKey: "sport_subtype_e_bike",
                    searchAliases: ["e-bike", "ebike", "electric bike", "e bike", "e-biking"],
                    systemImage: "bolt.fill"
                ),
                Subtype(
                    id: "casual_ride",
                    labelKey: "sport_subtype_casual_ride",
                    searchAliases: ["casual ride", "casual biking", "casual cycling"],
                    systemImage: "figure.outdoor.cycle"
                ),
                Subtype(
                    id: "other",
                    labelKey: "sport_subtype_other",
                    searchAliases: ["other cycling"],
                    systemImage: "ellipsis.circle"
                ),
            ]
        case .electricScooter:
            return [
                Subtype(
                    id: "group_ride",
                    labelKey: "sport_subtype_group_ride",
                    searchAliases: ["group ride", "escooter group"],
                    systemImage: "person.3.fill"
                ),
                Subtype(
                    id: "street_cruise",
                    labelKey: "sport_subtype_street_cruise",
                    searchAliases: ["street", "cruise", "street cruise"],
                    systemImage: "scooter"
                ),
                Subtype(
                    id: "trail_offroad",
                    labelKey: "sport_subtype_trail_offroad",
                    searchAliases: ["trail", "off-road", "offroad", "off road"],
                    systemImage: "leaf.fill"
                ),
                Subtype(
                    id: "other",
                    labelKey: "sport_subtype_other",
                    searchAliases: ["other scooter"],
                    systemImage: "ellipsis.circle"
                ),
            ]
        case .inlineSkating:
            return [
                Subtype(
                    id: "recreational",
                    labelKey: "sport_subtype_recreational",
                    searchAliases: ["recreational", "recreational skating"],
                    systemImage: "figure.skating"
                ),
                Subtype(
                    id: "fitness",
                    labelKey: "sport_subtype_fitness",
                    searchAliases: ["fitness", "fitness skating"],
                    systemImage: "figure.run"
                ),
                Subtype(
                    id: "urban_street",
                    labelKey: "sport_subtype_urban_street",
                    searchAliases: ["urban", "street skating", "urban street"],
                    systemImage: "building.2.fill"
                ),
                Subtype(
                    id: "speed",
                    labelKey: "sport_subtype_speed",
                    searchAliases: ["speed", "speed skating"],
                    systemImage: "gauge.with.needle"
                ),
                Subtype(
                    id: "other",
                    labelKey: "sport_subtype_other",
                    searchAliases: ["other skating"],
                    systemImage: "ellipsis.circle"
                ),
            ]
        }
    }

    // MARK: - Validation

    /// Returns a persisted subtype token, or nil when absent / invalid for the sport.
    static func normalizedSubtype(sport: String, subtype raw: String?) -> String? {
        guard hasSubtypes(forSport: sport) else { return nil }
        let token = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !token.isEmpty else { return nil }
        return subtypes(forSport: sport).first(where: { $0.id == token })?.id
    }

    static func defaultSubtype(forSport sport: String) -> String? {
        subtypes(forSport: sport).first?.id
    }

    static func ensuringValidSelection(_ raw: String?, sport: String) -> String? {
        if let valid = normalizedSubtype(sport: sport, subtype: raw) {
            return valid
        }
        return defaultSubtype(forSport: sport)
    }

    // MARK: - Copy

    static func pickerTitle(forSport sport: String, languageCode: String?) -> String {
        let key: String
        switch family(forSport: sport) {
        case .cycling:
            key = "sport_subtype_picker_cycling"
        case .electricScooter:
            key = "sport_subtype_picker_electric_scooter"
        case .inlineSkating:
            key = "sport_subtype_picker_inline_skating"
        case nil:
            return ""
        }
        return L10n.t(key, languageCode: languageCode)
    }

    static func displayLabel(forSubtype token: String, sport: String, languageCode: String?) -> String {
        let id = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let row = subtypes(forSport: sport).first(where: { $0.id == id }) {
            return L10n.t(row.labelKey, languageCode: languageCode)
        }
        return token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `Cycling · Mountain Biking`. Falls back to the sport label when subtype is absent.
    static func identityLine(
        sport: String,
        subtype: String?,
        languageCode: String?,
        compactSport: Bool = false
    ) -> String {
        let sportLabel = AppSportCatalog.displayLabel(
            forSportToken: sport,
            compact: compactSport
        )
        guard let subtype,
              let valid = normalizedSubtype(sport: sport, subtype: subtype) else {
            return sportLabel
        }
        let subtypeLabel = displayLabel(forSubtype: valid, sport: sport, languageCode: languageCode)
        if subtypeLabel.isEmpty { return sportLabel }
        if sportLabel.caseInsensitiveCompare(subtypeLabel) == .orderedSame {
            return sportLabel
        }
        return String(
            format: L10n.t("sport_subtype_identity_format", languageCode: languageCode),
            locale: Locale(identifier: L10n.normalizedLanguageCode(languageCode)),
            sportLabel,
            subtypeLabel
        )
    }

    /// Suggested activity title when the user has not entered a custom name.
    static func suggestedTitle(
        sport: String,
        subtype: String?,
        languageCode: String?
    ) -> String? {
        guard let family = family(forSport: sport) else { return nil }
        let token = normalizedSubtype(sport: sport, subtype: subtype)
            ?? defaultSubtype(forSport: sport)
            ?? ""
        let key: String?
        switch (family, token) {
        case (.cycling, "road_cycling"): key = "sport_subtype_title_road_cycling"
        case (.cycling, "mountain_biking"): key = "sport_subtype_title_mountain_biking"
        case (.cycling, "gravel"): key = "sport_subtype_title_gravel"
        case (.cycling, "bmx"): key = "sport_subtype_title_bmx"
        case (.cycling, "e_bike"): key = "sport_subtype_title_e_bike"
        case (.cycling, "casual_ride"): key = "sport_subtype_title_casual_ride"
        case (.cycling, "other"): key = "sport_subtype_title_cycling_other"
        case (.electricScooter, "group_ride"): key = "sport_subtype_title_escooter_group_ride"
        case (.electricScooter, "street_cruise"): key = "sport_subtype_title_escooter_street"
        case (.electricScooter, "trail_offroad"): key = "sport_subtype_title_escooter_trail"
        case (.electricScooter, "other"): key = "sport_subtype_title_escooter_other"
        case (.inlineSkating, "recreational"): key = "sport_subtype_title_inline_recreational"
        case (.inlineSkating, "fitness"): key = "sport_subtype_title_inline_fitness"
        case (.inlineSkating, "urban_street"): key = "sport_subtype_title_inline_urban"
        case (.inlineSkating, "speed"): key = "sport_subtype_title_inline_speed"
        case (.inlineSkating, "other"): key = "sport_subtype_title_inline_other"
        default: key = nil
        }
        guard let key else { return nil }
        return L10n.t(key, languageCode: languageCode)
    }

    // MARK: - Search

    static func matchesSearch(sport: String, subtype: String?, query raw: String) -> Bool {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return false }
        if SportFilterCatalog.storedSport(sport, matchesSearchQuery: q) {
            return true
        }
        let normalizedQuery = normalizedSearchText(q)
        guard !normalizedQuery.isEmpty else { return false }

        let rows: [Subtype]
        if let subtype, let valid = normalizedSubtype(sport: sport, subtype: subtype),
           let row = subtypes(forSport: sport).first(where: { $0.id == valid }) {
            rows = [row]
        } else {
            rows = subtypes(forSport: sport)
        }
        for row in rows {
            let label = L10n.t(row.labelKey, languageCode: "en")
            let fields = [row.id, label] + row.searchAliases
            for field in fields {
                let n = normalizedSearchText(field)
                if !n.isEmpty, n == normalizedQuery || n.contains(normalizedQuery) || normalizedQuery.contains(n) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Helpers

    private static func matchesAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }

    private static func normalizedSearchText(_ raw: String) -> String {
        raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined()
            .lowercased()
    }
}
