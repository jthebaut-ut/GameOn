import Foundation

/// Single source of truth for sport **strings** used in Calendar filters, pickup/venue pickers, analytics, and Supabase payloads.
/// Chip colors, SF Symbols, and search aliases live in ``SportFilterCatalog`` (SwiftUI).
public nonisolated enum AppSportCatalog {

    // MARK: - Grouped catalog (Discover “More”, pickup game form, venue Manage Games)

    /// Shared grouped sport model: fixed category order and row order inside each section.
    /// Row ``selection`` is the stored DB / filter token; ``label`` is novice-facing display text.
    public enum SportCatalog {
        public struct Category: Identifiable, Hashable {
            public let id: String
            public let title: String
            public let rows: [(label: String, selection: String)]

            public func hash(into hasher: inout Hasher) {
                hasher.combine(id)
            }

            public static func == (lhs: Category, rhs: Category) -> Bool {
                lhs.id == rhs.id
            }
        }

        /// Same sections as historical Discover “More”, expanded with additional sports (novice-friendly).
        public static let groupedCategories: [Category] = [
            Category(id: "motorsports", title: "Motorsports", rows: [
                ("Formula 1", "Formula 1"),
                ("NASCAR", "NASCAR"),
                ("MotoGP", "MotoGP"),
                ("Motocross", "Motocross"),
            ]),
            Category(id: "action", title: "Action", rows: [
                ("Climbing", "Climbing"),
                ("Skateboarding", "Skateboarding"),
                ("Electric Scooter", "Electric Scooter"),
                ("Inline Skating", "Inline Skating"),
                ("Paragliding", "paragliding"),
                ("Hang Gliding", "hang_gliding"),
                ("Paramotoring", "paramotoring"),
                ("Boxing", "Boxing"),
                ("MMA / UFC", "UFC"),
                ("Wrestling", "Wrestling"),
            ]),
            Category(id: "dance_urban", title: "Dance / Urban Sports", rows: [
                ("Break Dance", "Break Dance"),
            ]),
            Category(id: "dance_performing", title: "Dance / Performing Arts", rows: [
                ("Ballet", "Ballet"),
            ]),
            Category(id: "indoor", title: "Indoor", rows: [
                ("Badminton", "badminton"),
                ("Bowling", "Bowling"),
                ("Handball", "Handball"),
                ("Esports", "Esports"),
                ("Ping Pong", "Ping Pong"),
                ("Pickleball", "Pickleball"),
                ("Padel", "padel"),
            ]),
            Category(id: "water_winter", title: "Water/Winter", rows: [
                ("Swimming", "Swimming"),
                ("Skiing", "Skiing"),
            ]),
            Category(id: "endurance", title: "Running & cycling", rows: [
                ("Running", "Running"),
                ("Cycling", "Cycling"),
                ("Track & Field", "Track & Field"),
            ]),
            Category(id: "team", title: "Team Sports", rows: [
                ("Soccer", "Soccer"),
                ("Basketball", "NBA"),
                ("Football", "NFL"),
                ("Baseball", "Baseball"),
                ("Hockey", "NHL"),
                ("Golf", "Golf"),
                ("Tennis", "Tennis"),
                ("Volleyball", "Volleyball"),
                ("Cricket", "Cricket"),
                ("Rugby", "Rugby"),
                ("Softball", "Softball"),
                ("Lacrosse", "Lacrosse"),
            ]),
        ]

        /// Deduped selection tokens in category order (no `All`).
        public static var groupedSelectionTokensOrdered: [String] {
            var seen = Set<String>()
            var out: [String] = []
            out.reserveCapacity(48)
            for category in groupedCategories {
                for row in category.rows where seen.insert(row.selection).inserted {
                    out.append(row.selection)
                }
            }
            return out
        }

        /// Search filter for grouped sheets (category title + row label/selection).
        public static func filteredCategories(query raw: String) -> [Category] {
            let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { return groupedCategories }
            let normalizedQuery = normalizedCatalogSearchText(q)
            return groupedCategories.compactMap { category in
                if categoryMatchesSearch(category.title, query: q, normalizedQuery: normalizedQuery) {
                    return category
                }
                let rows = category.rows.filter { row in
                    rowMatchesSearch(row, query: q, normalizedQuery: normalizedQuery)
                }
                if rows.isEmpty { return nil }
                return Category(id: category.id, title: category.title, rows: rows)
            }
        }

        private static func rowMatchesSearch(
            _ row: (label: String, selection: String),
            query: String,
            normalizedQuery: String
        ) -> Bool {
            let fields = [row.label, row.selection] + searchAliases(forSelection: row.selection)
            return fields.contains { field in
                categoryMatchesSearch(field, query: query, normalizedQuery: normalizedQuery)
            }
        }

        private static func categoryMatchesSearch(_ value: String, query: String, normalizedQuery: String) -> Bool {
            value.localizedCaseInsensitiveContains(query)
                || normalizedCatalogSearchText(value).contains(normalizedQuery)
        }

        private static func normalizedCatalogSearchText(_ raw: String) -> String {
            raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined()
                .lowercased()
        }

        private static func searchAliases(forSelection selection: String) -> [String] {
            switch selection.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "break dance":
                return ["breakdance", "breaking", "urban dance", "dance"]
            case "ballet":
                return ["performing arts", "classical ballet", "dance"]
            case "paragliding":
                return ["parapente", "paraglider", "para gliding"]
            case "hang_gliding", "hang gliding":
                return ["deltaplane", "hanggliding", "hang glider", "hang-gliding"]
            case "paramotoring":
                return ["paramoteur", "powered paragliding", "paramotor"]
            case "padel":
                // Typo / FR-identical display alias only — never a canonical stored ID.
                return ["padle"]
            case "cycling":
                return [
                    "biking", "bike", "bicycle", "road cycling", "road bike", "road biking",
                    "mountain biking", "mountain bike", "mtb", "gravel", "bmx",
                    "e-bike", "ebike", "electric bike", "casual ride"
                ]
            case "electric scooter":
                return ["electric scooter", "e-scooter", "escooter", "e scooter", "scooter"]
            case "inline skating":
                return [
                    "inline skating", "inline skates", "rollerblading", "rollerblades",
                    "roller blades", "rollerblade"
                ]
            default:
                return []
            }
        }
    }

    /// Alias for grouped picker sections (`SportCatalog.Category`).
    public typealias SportCategory = SportCatalog.Category

    /// Tokens that appear in filters/history as friendly names but map to league chips elsewhere.
    private static let legacyFriendlySportTokens: [String] = ["Basketball", "Football", "Hockey"]

    /// Distinct ordered list including `All`, league tokens (NBA/NFL/NHL), friendly aliases, and grouped catalog sports.
    public static let calendarAndPickerSportsOrdered: [String] = {
        var seen = Set<String>()
        var out: [String] = []
        out.reserveCapacity(64)

        func append(_ s: String) {
            guard seen.insert(s).inserted else { return }
            out.append(s)
        }

        append("All")

        let toolbarPriority: [String] = [
            "Soccer", "Basketball", "Football", "Baseball", "Hockey", "Golf",
            "NBA", "NFL", "NHL",
            "Tennis", "badminton", "Volleyball", "Ping Pong", "UFC", "Formula 1",
        ]
        for s in toolbarPriority { append(s) }

        for s in SportCatalog.groupedSelectionTokensOrdered { append(s) }

        for s in legacyFriendlySportTokens { append(s) }

        return out
    }()

    public static var sportsExcludingAll: [String] {
        calendarAndPickerSportsOrdered.filter { $0 != "All" }
    }

    /// Canonical stored token for form pickers / Open To (e.g. `Hockey` / `NHL` → `NHL`).
    /// Calendar filters intentionally keep both friendly and league strings; forms must not.
    public static func canonicalFormPickerToken(for raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let lowered = trimmed.lowercased()
        if lowered == "biking" || lowered == "bike" || lowered == "bicycle" {
            return "Cycling"
        }
        if lowered == "e-scooter" || lowered == "escooter" || lowered == "e scooter" {
            return "Electric Scooter"
        }
        if lowered == "rollerblading" || lowered == "rollerblades" || lowered == "rollerblade"
            || lowered == "roller blades" || lowered == "inline skates" {
            return "Inline Skating"
        }

        for category in SportCatalog.groupedCategories {
            if let row = category.rows.first(where: {
                $0.selection.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
                    || $0.label.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
            }) {
                return row.selection
            }
        }

        if let pair = discoverMapDefaultPopularPairs.first(where: {
            $0.selection.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
                || $0.display.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return pair.selection
        }

        return trimmed
    }

    /// Stored sport tokens that should match a Discover/Going sport chip, including legacy aliases.
    public static func storedTokensMatchingDiscoverFilter(_ selected: String) -> [String] {
        let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("All") == .orderedSame {
            return []
        }
        let canonical = canonicalFormPickerToken(for: trimmed)
        var tokens = [canonical, trimmed]
        if canonical.caseInsensitiveCompare("Cycling") == .orderedSame {
            tokens.append(contentsOf: ["Biking", "biking"])
        }
        var seen = Set<String>()
        return tokens.filter { seen.insert($0.lowercased()).inserted }
    }

    public static func sport(_ stored: String, matchesDiscoverSelection selected: String) -> Bool {
        let selectedTrimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedTrimmed.isEmpty || selectedTrimmed.caseInsensitiveCompare("All") == .orderedSame {
            return true
        }
        let storedTrimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if storedTrimmed.isEmpty { return false }
        let allowed = storedTokensMatchingDiscoverFilter(selectedTrimmed)
        if allowed.contains(where: { $0.caseInsensitiveCompare(storedTrimmed) == .orderedSame }) {
            return true
        }
        let storedCanonical = canonicalFormPickerToken(for: storedTrimmed)
        return allowed.contains(where: { $0.caseInsensitiveCompare(storedCanonical) == .orderedSame })
    }

    /// English catalog label for a stored token (no localization) — used for dedupe keys / DEBUG asserts.
    public static func catalogEnglishLabel(forSportToken token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let canonical = canonicalFormPickerToken(for: trimmed)

        for category in SportCatalog.groupedCategories {
            if let row = category.rows.first(where: {
                $0.selection.localizedCaseInsensitiveCompare(canonical) == .orderedSame
                    || $0.label.localizedCaseInsensitiveCompare(canonical) == .orderedSame
                    || $0.selection.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
                    || $0.label.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
            }) {
                return row.label
            }
        }

        if let pair = discoverMapDefaultPopularPairs.first(where: {
            $0.selection.localizedCaseInsensitiveCompare(canonical) == .orderedSame
                || $0.display.localizedCaseInsensitiveCompare(canonical) == .orderedSame
                || $0.selection.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
                || $0.display.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return pair.display
        }

        return canonical
    }

    /// Stored sport strings for pickup + venue owner game forms and Open To.
    /// Same toolbar-priority order as ``sportsExcludingAll``, but friendly↔league aliases
    /// (`Basketball`/`NBA`, `Football`/`NFL`, `Hockey`/`NHL`) collapse to one canonical token.
    /// Does **not** change ``calendarAndPickerSportsOrdered`` / filter token lists.
    public static let formPickerSportsOrdered: [String] = {
        var seenTokens = Set<String>()
        var seenDisplayNames = Set<String>()
        var out: [String] = []
        out.reserveCapacity(48)

        for raw in calendarAndPickerSportsOrdered where raw != "All" {
            let token = canonicalFormPickerToken(for: raw)
            let displayKey = catalogEnglishLabel(forSportToken: token)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !displayKey.isEmpty else { continue }
            guard seenTokens.insert(token).inserted else { continue }
            guard seenDisplayNames.insert(displayKey).inserted else { continue }
            out.append(token)
        }

        return out
    }()

    /// Friendly label for a stored sport token, e.g. `NBA` -> `Basketball`.
    /// Uses ``L10n`` so catalog English labels resolve to the active app language (e.g. Parapente).
    /// `compact` uses a shorter chip label where one exists (`Electric Scooter` → `E-Scooter`).
    public static func displayLabel(forSportToken token: String, compact: Bool = false) -> String {
        let english = catalogEnglishLabel(forSportToken: token)
        guard !english.isEmpty else { return "" }
        if compact, english.caseInsensitiveCompare("Electric Scooter") == .orderedSame {
            return L10n.t("E-Scooter")
        }
        return L10n.t(english)
    }

    /// Compact Discover toolbar: stored selection token + chip label (see ``DiscoverSportFilterRowLayout``).
    public static let discoverMapDefaultPopularPairs: [(selection: String, display: String)] = [
        ("Soccer", "Soccer"),
        ("NBA", "Basketball"),
        ("NFL", "Football"),
        ("Baseball", "Baseball"),
        ("NHL", "Hockey"),
        ("Golf", "Golf"),
    ]
}
