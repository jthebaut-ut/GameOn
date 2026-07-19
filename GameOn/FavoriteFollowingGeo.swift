import Foundation

/// Continent chips for Following browse. Shared, deterministic, local-only.
/// Pure domain — must stay nonisolated under default MainActor isolation.
nonisolated enum FavoriteFollowingContinent: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all
    case northAmerica
    case southAmerica
    case europe
    case asia
    case africa
    case oceania
    case other

    var id: String { rawValue }

    /// Display key for localization (`following_region_*`).
    var localizationKey: String {
        switch self {
        case .all: return "following_region_all"
        case .northAmerica: return "following_region_north_america"
        case .southAmerica: return "following_region_south_america"
        case .europe: return "following_region_europe"
        case .asia: return "following_region_asia"
        case .africa: return "following_region_africa"
        case .oceania: return "following_region_oceania"
        case .other: return "following_region_other"
        }
    }

    var symbolName: String {
        switch self {
        case .all: return "globe"
        case .northAmerica, .southAmerica: return "globe.americas.fill"
        case .europe: return "globe.europe.africa.fill"
        case .asia: return "globe.asia.australia.fill"
        case .africa: return "globe.europe.africa.fill"
        case .oceania: return "globe.asia.australia.fill"
        case .other: return "questionmark.circle"
        }
    }

    /// Chip row order excluding `.other` (shown only when unclassified content exists).
    static var primaryCases: [FavoriteFollowingContinent] {
        [.all, .northAmerica, .southAmerica, .europe, .asia, .africa, .oceania]
    }

    /// Canonical continent label as stored on many catalog `region` fields.
    var catalogLabel: String? {
        switch self {
        case .all, .other: return nil
        case .northAmerica: return "North America"
        case .southAmerica: return "South America"
        case .europe: return "Europe"
        case .asia: return "Asia"
        case .africa: return "Africa"
        case .oceania: return "Oceania"
        }
    }

    static func fromCatalogLabel(_ raw: String) -> FavoriteFollowingContinent? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "north america", "northamerica", "concacaf": return .northAmerica
        case "south america", "southamerica", "conmebol": return .southAmerica
        case "europe", "uefa": return .europe
        case "asia", "afc": return .asia
        case "africa", "caf": return .africa
        case "oceania", "ofc": return .oceania
        default: return nil
        }
    }
}

/// Country option for the Following country sheet.
/// Pure domain — display strings are supplied by the caller (View localizes).
nonisolated struct FavoriteFollowingCountryOption: Identifiable, Hashable, Sendable {
    /// ISO 3166-1 alpha-2 when known; `"__all__"` for All countries; `"__other__"` for unclassified.
    let id: String
    let displayName: String
    let continent: FavoriteFollowingContinent
    let itemCount: Int

    static let allID = "__all__"
    static let otherID = "__other__"

    var isAll: Bool { id == Self.allID }
    var isOther: Bool { id == Self.otherID }
}

/// Local geo helpers for Following filters. No network; no backend.
nonisolated enum FavoriteFollowingGeo {
    /// ISO alpha-2 → continent. Unlisted codes resolve to `.other`.
    private static let isoToContinent: [String: FavoriteFollowingContinent] = [
        // North America / Central America / Caribbean
        "US": .northAmerica, "CA": .northAmerica, "MX": .northAmerica, "GT": .northAmerica,
        "BZ": .northAmerica, "SV": .northAmerica, "HN": .northAmerica, "NI": .northAmerica,
        "CR": .northAmerica, "PA": .northAmerica, "CU": .northAmerica, "JM": .northAmerica,
        "HT": .northAmerica, "DO": .northAmerica, "PR": .northAmerica, "TT": .northAmerica,
        "BB": .northAmerica, "BS": .northAmerica, "CW": .northAmerica, "GP": .northAmerica,
        "MQ": .northAmerica, "GD": .northAmerica, "LC": .northAmerica, "VC": .northAmerica,
        "AG": .northAmerica, "KN": .northAmerica, "DM": .northAmerica, "KY": .northAmerica,
        "BM": .northAmerica, "AW": .northAmerica, "SX": .northAmerica, "TC": .northAmerica,
        // South America
        "BR": .southAmerica, "AR": .southAmerica, "CL": .southAmerica, "UY": .southAmerica,
        "PY": .southAmerica, "BO": .southAmerica, "PE": .southAmerica, "EC": .southAmerica,
        "CO": .southAmerica, "VE": .southAmerica, "GY": .southAmerica, "SR": .southAmerica,
        "GF": .southAmerica,
        // Europe
        "GB": .europe, "IE": .europe, "FR": .europe, "ES": .europe, "PT": .europe, "DE": .europe,
        "IT": .europe, "NL": .europe, "BE": .europe, "LU": .europe, "CH": .europe, "AT": .europe,
        "PL": .europe, "CZ": .europe, "SK": .europe, "HU": .europe, "RO": .europe, "BG": .europe,
        "GR": .europe, "TR": .europe, "SE": .europe, "NO": .europe, "DK": .europe, "FI": .europe,
        "IS": .europe, "EE": .europe, "LV": .europe, "LT": .europe, "UA": .europe, "BY": .europe,
        "MD": .europe, "RS": .europe, "HR": .europe, "SI": .europe, "BA": .europe, "ME": .europe,
        "MK": .europe, "AL": .europe, "XK": .europe, "MT": .europe, "CY": .europe, "GE": .europe,
        "AM": .europe, "AZ": .europe, "RU": .europe, "AD": .europe, "MC": .europe, "SM": .europe,
        "LI": .europe, "FO": .europe, "GI": .europe,
        // Asia
        "CN": .asia, "JP": .asia, "KR": .asia, "KP": .asia, "TW": .asia, "HK": .asia, "MO": .asia,
        "MN": .asia, "IN": .asia, "PK": .asia, "BD": .asia, "LK": .asia, "NP": .asia, "BT": .asia,
        "MV": .asia, "AF": .asia, "IR": .asia, "IQ": .asia, "SY": .asia, "LB": .asia, "JO": .asia,
        "IL": .asia, "PS": .asia, "SA": .asia, "AE": .asia, "QA": .asia, "BH": .asia, "KW": .asia,
        "OM": .asia, "YE": .asia, "TH": .asia, "VN": .asia, "MY": .asia, "SG": .asia, "ID": .asia,
        "PH": .asia, "MM": .asia, "KH": .asia, "LA": .asia, "BN": .asia, "TL": .asia, "UZ": .asia,
        "KZ": .asia, "KG": .asia, "TJ": .asia, "TM": .asia,
        // Africa
        "EG": .africa, "MA": .africa, "DZ": .africa, "TN": .africa, "LY": .africa, "SD": .africa,
        "SS": .africa, "ET": .africa, "ER": .africa, "DJ": .africa, "SO": .africa, "KE": .africa,
        "UG": .africa, "TZ": .africa, "RW": .africa, "BI": .africa, "NG": .africa, "GH": .africa,
        "CI": .africa, "SN": .africa, "CM": .africa, "ZA": .africa, "ZW": .africa, "ZM": .africa,
        "MW": .africa, "MZ": .africa, "AO": .africa, "CD": .africa, "CG": .africa, "GA": .africa,
        "GQ": .africa, "ST": .africa, "CV": .africa, "GM": .africa, "GN": .africa, "GW": .africa,
        "SL": .africa, "LR": .africa, "ML": .africa, "BF": .africa, "NE": .africa, "TD": .africa,
        "CF": .africa, "MR": .africa, "EH": .africa, "BW": .africa, "NA": .africa, "LS": .africa,
        "SZ": .africa, "MG": .africa, "MU": .africa, "SC": .africa, "KM": .africa,
        // Oceania
        "AU": .oceania, "NZ": .oceania, "FJ": .oceania, "PG": .oceania, "SB": .oceania,
        "VU": .oceania, "NC": .oceania, "PF": .oceania, "WS": .oceania, "TO": .oceania,
        "TV": .oceania, "KI": .oceania, "NR": .oceania, "PW": .oceania, "FM": .oceania,
        "MH": .oceania, "GU": .oceania, "MP": .oceania, "AS": .oceania, "CK": .oceania
    ]

    /// League/competition home country for club filtering (deterministic local map).
    private static let leagueHomeISO: [String: String] = [
        "Premier League": "GB",
        "Women's Super League": "GB",
        "Scottish Premiership": "GB",
        "La Liga": "ES",
        "Liga F": "ES",
        "Serie A": "IT",
        "Serie A Femminile": "IT",
        "Bundesliga": "DE",
        "Frauen-Bundesliga": "DE",
        "Ligue 1": "FR",
        "Division 1 Féminine": "FR",
        "Primeira Liga": "PT",
        "Eredivisie": "NL",
        "Belgian Pro League": "BE",
        "Austrian Bundesliga": "AT",
        "Swiss Super League": "CH",
        "Süper Lig": "TR",
        "Greek Super League": "GR",
        "Botola Pro": "MA",
        "Tunisian Ligue 1": "TN",
        "Egyptian Premier League": "EG",
        "South African Premiership": "ZA",
        "MLS": "US",
        "NWSL": "US",
        "NBA": "US",
        "WNBA": "US",
        "NFL": "US",
        "MLB": "US",
        "Pro Hockey": "US",
        "CFL": "CA",
        "College Basketball": "US",
        "College Football": "US",
        "Liga MX": "MX",
        "LFA Mexico": "MX",
        "Brazil Serie A": "BR",
        "Argentina Primera Division": "AR",
        "J1 League": "JP",
        "Saudi Pro League": "SA",
        "K League": "KR",
        "A-League Men": "AU",
        "Liga ACB": "ES",
        "LNB Pro A": "FR",
        "BBL Germany": "DE",
        "Lega Basket Serie A": "IT",
        "BSL Turkey": "TR",
        "Greek Basket League": "GR",
        "Lithuanian LKL": "LT",
        "Adriatic League": "RS",
        "NBL Australia": "AU",
        "B.League Japan": "JP",
        "KBL Korea": "KR",
        "CBA China": "CN",
        "PBA Philippines": "PH",
        "Liga Nacional Argentina": "AR",
        "NBB Brazil": "BR",
        "LNB Chile": "CL",
        "LUB Uruguay": "UY",
        "BAL Africa": "EG",
        "ELF": "DE",
        "GFL Germany": "DE",
        "XLeague Japan": "JP",
        "NPB Japan": "JP",
        "KBO Korea": "KR",
        "CPBL Taiwan": "TW",
        "Mexican League": "MX",
        "Australian Baseball League": "AU",
        "KHL": "RU",
        "SHL Sweden": "SE",
        "Liiga Finland": "FI",
        "DEL Germany": "DE",
        "National League Switzerland": "CH",
        "Extraliga Czechia": "CZ",
        "EIHL UK": "GB",
        "ICEHL": "AT",
        "Indian Premier League": "IN",
        "Big Bash League": "AU",
        "Pakistan Super League": "PK",
        "The Hundred": "GB",
        "Super Rugby Pacific": "NZ",
        "United Rugby Championship": "IE",
        "Premiership Rugby": "GB",
        "National Rugby League": "AU"
    ]

    static func continent(forISOCode code: String) -> FavoriteFollowingContinent {
        let key = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return isoToContinent[key] ?? .other
    }

    static func continent(forTeam team: FavoriteTeam) -> FavoriteFollowingContinent {
        if let fromRegion = FavoriteFollowingContinent.fromCatalogLabel(team.region) {
            return fromRegion
        }
        if let iso = isoCountryCode(for: team) {
            return continent(forISOCode: iso)
        }
        return .other
    }

    /// Best-effort ISO for country filtering. Nil ⇒ unclassified.
    static func isoCountryCode(for team: FavoriteTeam) -> String? {
        if team.kind == .nationalTeam {
            if let code = CountryFlagHelper.countryCode(for: team.name) {
                return code.uppercased()
            }
        }
        let leagueKey = team.league.trimmingCharacters(in: .whitespacesAndNewlines)
        if let home = leagueHomeISO[leagueKey] {
            return home
        }
        // Some catalog rows store league-ish labels on `region`.
        if let home = leagueHomeISO[team.region.trimmingCharacters(in: .whitespacesAndNewlines)] {
            return home
        }
        return nil
    }

    static func matchesContinent(_ team: FavoriteTeam, _ continent: FavoriteFollowingContinent) -> Bool {
        guard continent != .all else { return true }
        return self.continent(forTeam: team) == continent
    }

    static func matchesCountry(_ team: FavoriteTeam, countryID: String) -> Bool {
        if countryID == FavoriteFollowingCountryOption.allID { return true }
        if countryID == FavoriteFollowingCountryOption.otherID {
            return isoCountryCode(for: team) == nil
        }
        guard let iso = isoCountryCode(for: team) else { return false }
        return iso.caseInsensitiveCompare(countryID) == .orderedSame
    }

    /// Locale display name for an ISO region. `languageCode` should already be normalized by the caller.
    static func localizedCountryName(isoCode: String, languageCode: String) -> String {
        let code = isoCode.uppercased()
        let localeID = languageCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if !localeID.isEmpty,
           let name = Locale(identifier: localeID).localizedString(forRegionCode: code) {
            return name
        }
        return Locale(identifier: "en").localizedString(forRegionCode: code) ?? code
    }

    /// Countries present in `teams`, optionally constrained to a continent chip.
    /// `allCountriesTitle` / `unclassifiedTitle` must be localized by the View (keeps this helper L10n-free).
    static func countryOptions(
        from teams: [FavoriteTeam],
        continent: FavoriteFollowingContinent,
        languageCode: String,
        allCountriesTitle: String,
        unclassifiedTitle: String
    ) -> [FavoriteFollowingCountryOption] {
        var counts: [String: Int] = [:]
        var continents: [String: FavoriteFollowingContinent] = [:]
        var otherCount = 0

        for team in teams {
            guard matchesContinent(team, continent) else { continue }
            if let iso = isoCountryCode(for: team) {
                counts[iso, default: 0] += 1
                continents[iso] = self.continent(forISOCode: iso)
            } else {
                otherCount += 1
            }
        }

        var options: [FavoriteFollowingCountryOption] = [
            FavoriteFollowingCountryOption(
                id: FavoriteFollowingCountryOption.allID,
                displayName: allCountriesTitle,
                continent: .all,
                itemCount: teams.filter { matchesContinent($0, continent) }.count
            )
        ]

        let sortedISO = counts.keys.sorted {
            localizedCountryName(isoCode: $0, languageCode: languageCode)
                .localizedCaseInsensitiveCompare(localizedCountryName(isoCode: $1, languageCode: languageCode))
                == .orderedAscending
        }
        for iso in sortedISO {
            options.append(
                FavoriteFollowingCountryOption(
                    id: iso,
                    displayName: localizedCountryName(isoCode: iso, languageCode: languageCode),
                    continent: continents[iso] ?? .other,
                    itemCount: counts[iso] ?? 0
                )
            )
        }

        if otherCount > 0 {
            options.append(
                FavoriteFollowingCountryOption(
                    id: FavoriteFollowingCountryOption.otherID,
                    displayName: unclassifiedTitle,
                    continent: .other,
                    itemCount: otherCount
                )
            )
        }
        return options
    }

    static func continentsWithResults(in teams: [FavoriteTeam]) -> Set<FavoriteFollowingContinent> {
        Set(teams.map(continent(forTeam:)))
    }
}
