import Foundation

/// Search metadata that associates IANA zones with country/territory names for picker search.
enum FanGeoTimeZoneSearchMetadata: Sendable {
    nonisolated private static let cache: [String: [String]] = buildSearchTermCache()

    nonisolated static func searchTerms(for identifier: String) -> [String] {
        cache[identifier] ?? []
    }

    nonisolated static func matchesQuery(_ query: String, identifier: String) -> Bool {
        let needle = normalized(query)
        guard !needle.isEmpty else { return true }
        return searchTerms(for: identifier).contains { normalized($0).contains(needle) }
    }

    nonisolated static func matchedIdentifierCount(for query: String) -> Int {
        let needle = normalized(query)
        guard !needle.isEmpty else {
            return TimeZone.knownTimeZoneIdentifiers.count
        }
        return TimeZone.knownTimeZoneIdentifiers.reduce(into: 0) { count, identifier in
            if matchesCatalogQuery(needle, identifier: identifier) {
                count += 1
            }
        }
    }

    /// Shared search logic used by the catalog and debug validation.
    nonisolated static func matchesCatalogQuery(_ needle: String, identifier: String) -> Bool {
        if identifier.lowercased().contains(needle) { return true }

        let city = primaryRowTitle(for: identifier, timeZone: TimeZone(identifier: identifier))
        if city.lowercased().contains(needle) { return true }

        if let zone = TimeZone(identifier: identifier) {
            let locale = FanGeoTimeZoneCatalogFormatting.displayLocale
            let names = [
                zone.localizedName(for: .standard, locale: locale),
                zone.localizedName(for: .shortStandard, locale: locale),
                zone.localizedName(for: .daylightSaving, locale: locale),
                zone.localizedName(for: .generic, locale: locale)
            ]
            if names.contains(where: { ($0 ?? "").lowercased().contains(needle) }) {
                return true
            }
        }

        let region = FanGeoTimeZoneRegion.region(for: identifier).sectionTitle.lowercased()
        if region.contains(needle) { return true }

        if matchesQuery(needle, identifier: identifier) { return true }
        return false
    }

    /// Primary country or territory label for picker presentation.
    nonisolated static func primaryCountryLabel(for identifier: String) -> String {
        if unitedStatesIdentifiers.contains(identifier) { return "United States" }
        if canadaIdentifiers.contains(identifier) { return "Canada" }
        if mexicoIdentifiers.contains(identifier) { return "Mexico" }
        if russianIdentifiers.contains(identifier) { return "Russia" }
        if unitedKingdomIdentifiers.contains(identifier) { return "United Kingdom" }
        if newZealandIdentifiers.contains(identifier) { return "New Zealand" }
        if identifier.hasPrefix("Australia/") { return "Australia" }
        if identifier == "Asia/Kolkata" || identifier == "Asia/Calcutta" { return "India" }
        if identifier == "Asia/Tokyo" { return "Japan" }

        if let explicit = explicitCountryTerms[identifier]?.first {
            return explicit
        }
        if identifier.hasPrefix("Europe/"), let country = europeanCountry(for: identifier) {
            return country
        }
        if identifier.hasPrefix("Africa/"), let country = africanCountry(for: identifier) {
            return country
        }
        if identifier.hasPrefix("Asia/"),
           !russianIdentifiers.contains(identifier),
           let country = asianCountry(for: identifier) {
            return country
        }
        if identifier.hasPrefix("Pacific/"),
           !newZealandIdentifiers.contains(identifier),
           let country = pacificCountry(for: identifier) {
            return country
        }
        if identifier.hasPrefix("America/"),
           !unitedStatesIdentifiers.contains(identifier),
           !canadaIdentifiers.contains(identifier),
           !mexicoIdentifiers.contains(identifier),
           let country = americasCountry(for: identifier) {
            return country
        }
        if identifier.hasPrefix("Atlantic/"), let country = atlanticCountry(for: identifier) {
            return country
        }
        if identifier.hasPrefix("Indian/"), let country = indianOceanCountry(for: identifier) {
            return country
        }
        if identifier == "UTC" || identifier.hasPrefix("Etc/") {
            return "UTC"
        }
        return FanGeoTimeZoneRegion.region(for: identifier).sectionTitle
    }

    nonisolated private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    nonisolated private static func buildSearchTermCache() -> [String: [String]] {
        var cache: [String: Set<String>] = [:]
        for identifier in TimeZone.knownTimeZoneIdentifiers {
            guard TimeZone(identifier: identifier) != nil else { continue }
            var terms = Set<String>()
            terms.formUnion(countryTerms(for: identifier))
            terms.insert(FanGeoTimeZoneRegion.region(for: identifier).sectionTitle)
            cache[identifier] = terms
        }
        return cache.mapValues { Array($0).sorted() }
    }

    nonisolated private static func countryTerms(for identifier: String) -> [String] {
        var terms: [String] = []

        if let explicit = explicitCountryTerms[identifier] {
            terms.append(contentsOf: explicit)
        }

        if unitedStatesIdentifiers.contains(identifier) {
            terms.append(contentsOf: ["United States", "USA", "US", "U.S.", "United States of America"])
        }
        if canadaIdentifiers.contains(identifier) {
            terms.append(contentsOf: ["Canada"])
        }
        if mexicoIdentifiers.contains(identifier) {
            terms.append(contentsOf: ["Mexico"])
        }
        if russianIdentifiers.contains(identifier) {
            terms.append(contentsOf: ["Russia", "Russian Federation"])
        }
        if identifier.hasPrefix("Australia/") {
            terms.append("Australia")
        }
        if newZealandIdentifiers.contains(identifier) {
            terms.append(contentsOf: ["New Zealand"])
        }
        if identifier == "Asia/Kolkata" || identifier == "Asia/Calcutta" {
            terms.append(contentsOf: ["India"])
        }
        if identifier == "Asia/Tokyo" {
            terms.append(contentsOf: ["Japan"])
        }
        if identifier == "Europe/Paris" {
            terms.append(contentsOf: ["France"])
        }
        if unitedKingdomIdentifiers.contains(identifier) {
            terms.append(contentsOf: ["United Kingdom", "UK", "Britain", "Great Britain", "England", "Scotland", "Wales", "Northern Ireland"])
        }
        if identifier.hasPrefix("Europe/") && !unitedKingdomIdentifiers.contains(identifier) && !russianIdentifiers.contains(identifier) {
            if let country = europeanCountry(for: identifier) {
                terms.append(country)
            }
        }
        if identifier.hasPrefix("Africa/") {
            if let country = africanCountry(for: identifier) {
                terms.append(country)
            }
        }
        if identifier.hasPrefix("Asia/") && !russianIdentifiers.contains(identifier) {
            if let country = asianCountry(for: identifier) {
                terms.append(country)
            }
        }
        if identifier.hasPrefix("Pacific/") && !newZealandIdentifiers.contains(identifier) {
            if let country = pacificCountry(for: identifier) {
                terms.append(country)
            }
        }
        if identifier.hasPrefix("America/") && !unitedStatesIdentifiers.contains(identifier)
            && !canadaIdentifiers.contains(identifier) && !mexicoIdentifiers.contains(identifier) {
            if let country = americasCountry(for: identifier) {
                terms.append(country)
            }
        }
        if identifier.hasPrefix("Atlantic/") {
            if let country = atlanticCountry(for: identifier) {
                terms.append(country)
            }
        }
        if identifier.hasPrefix("Indian/") {
            if let country = indianOceanCountry(for: identifier) {
                terms.append(country)
            }
        }

        return Array(Set(terms))
    }

    nonisolated private static let explicitCountryTerms: [String: [String]] = [
        "Europe/Dublin": ["Ireland"],
        "Europe/Lisbon": ["Portugal"],
        "Europe/Istanbul": ["Turkey", "Türkiye"],
        "Asia/Dubai": ["United Arab Emirates", "UAE"],
        "Asia/Qatar": ["Qatar"],
        "Asia/Singapore": ["Singapore"],
        "Asia/Hong_Kong": ["Hong Kong"],
        "Asia/Macau": ["Macau"],
        "Asia/Taipei": ["Taiwan"],
        "Asia/Seoul": ["South Korea", "Korea"],
        "Asia/Bangkok": ["Thailand"],
        "Asia/Jakarta": ["Indonesia"],
        "Asia/Manila": ["Philippines"],
        "Asia/Kuala_Lumpur": ["Malaysia"],
        "Asia/Jerusalem": ["Israel"],
        "Asia/Riyadh": ["Saudi Arabia"],
        "Asia/Tehran": ["Iran"],
        "Asia/Karachi": ["Pakistan"],
        "Asia/Dhaka": ["Bangladesh"],
        "Asia/Colombo": ["Sri Lanka"],
        "Asia/Kathmandu": ["Nepal"],
        "Pacific/Honolulu": ["United States", "USA", "US", "Hawaii"],
        "Pacific/Guam": ["Guam", "United States", "USA"],
        "Pacific/Saipan": ["Northern Mariana Islands", "United States", "USA"],
        "Pacific/Pago_Pago": ["American Samoa", "United States", "USA"],
    ]

    nonisolated private static let unitedKingdomIdentifiers: Set<String> = [
        "Europe/London", "Europe/Belfast", "Europe/Guernsey", "Europe/Isle_of_Man", "Europe/Jersey"
    ]

    nonisolated private static let newZealandIdentifiers: Set<String> = [
        "Pacific/Auckland", "Pacific/Chatham"
    ]

    nonisolated private static let russianIdentifiers: Set<String> = [
        "Europe/Kaliningrad", "Europe/Moscow", "Europe/Simferopol", "Europe/Kirov", "Europe/Volgograd",
        "Europe/Astrakhan", "Europe/Saratov", "Europe/Ulyanovsk", "Europe/Samara",
        "Asia/Yekaterinburg", "Asia/Omsk", "Asia/Novosibirsk", "Asia/Barnaul", "Asia/Tomsk",
        "Asia/Novokuznetsk", "Asia/Krasnoyarsk", "Asia/Irkutsk", "Asia/Chita", "Asia/Yakutsk",
        "Asia/Khandyga", "Asia/Vladivostok", "Asia/Ust-Nera", "Asia/Magadan", "Asia/Sakhalin",
        "Asia/Srednekolymsk", "Asia/Kamchatka", "Asia/Anadyr"
    ]

    nonisolated private static let canadaIdentifiers: Set<String> = {
        let exact: Set<String> = [
            "America/St_Johns", "America/Halifax", "America/Glace_Bay", "America/Goose_Bay", "America/Moncton",
            "America/Toronto", "America/Nipigon", "America/Thunder_Bay", "America/Winnipeg", "America/Rainy_River",
            "America/Atikokan", "America/Pangnirtung", "America/Iqaluit", "America/Resolute", "America/Rankin_Inlet",
            "America/Regina", "America/Swift_Current", "America/Edmonton", "America/Vancouver", "America/Dawson",
            "America/Whitehorse", "America/Yellowknife", "America/Inuvik", "America/Cambridge_Bay", "America/Creston",
            "America/Dawson_Creek", "America/Fort_Nelson", "America/Blanc-Sablon"
        ]
        let prefixed = TimeZone.knownTimeZoneIdentifiers.filter { $0.hasPrefix("Canada/") }
        return exact.union(prefixed)
    }()

    nonisolated private static let mexicoIdentifiers: Set<String> = [
        "America/Mexico_City", "America/Cancun", "America/Merida", "America/Monterrey", "America/Matamoros",
        "America/Chihuahua", "America/Ojinaga", "America/Hermosillo", "America/Mazatlan", "America/Bahia_Banderas",
        "America/Tijuana"
    ]

    nonisolated private static let nonUnitedStatesAmericaIdentifiers: Set<String> = {
        var excluded = canadaIdentifiers
        excluded.formUnion(mexicoIdentifiers)
        excluded.formUnion([
            "America/Anguilla", "America/Antigua", "America/Aruba", "America/Asuncion", "America/Barbados",
            "America/Belize", "America/Bogota", "America/Buenos_Aires", "America/Caracas", "America/Catamarca",
            "America/Cayenne", "America/Cayman", "America/Costa_Rica", "America/Cuiaba", "America/Curacao",
            "America/Danmarkshavn", "America/Dominica", "America/El_Salvador", "America/Fortaleza", "America/Godthab",
            "America/Grand_Turk", "America/Grenada", "America/Guadeloupe", "America/Guatemala", "America/Guayaquil",
            "America/Guyana", "America/Havana", "America/Jamaica", "America/Jujuy", "America/Kralendijk",
            "America/La_Paz", "America/Lima", "America/Lower_Princes", "America/Maceio", "America/Managua",
            "America/Manaus", "America/Marigot", "America/Martinique", "America/Mendoza", "America/Miquelon",
            "America/Montevideo", "America/Montserrat", "America/Nassau", "America/Noronha", "America/Nuuk",
            "America/Panama", "America/Paramaribo", "America/Port-au-Prince", "America/Port_of_Spain",
            "America/Porto_Velho", "America/Puerto_Rico", "America/Punta_Arenas", "America/Recife",
            "America/Rio_Branco", "America/Santarem", "America/Santiago", "America/Santo_Domingo", "America/Sao_Paulo",
            "America/Scoresbysund", "America/St_Barthelemy", "America/St_Kitts", "America/St_Lucia",
            "America/St_Thomas", "America/St_Vincent", "America/Tegucigalpa", "America/Thule", "America/Tortola"
        ])
        let argentinaZones = TimeZone.knownTimeZoneIdentifiers.filter { $0.hasPrefix("America/Argentina") }
        excluded.formUnion(argentinaZones)
        return excluded
    }()

    nonisolated private static let unitedStatesIdentifiers: Set<String> = {
        Set(TimeZone.knownTimeZoneIdentifiers.filter {
            ($0.hasPrefix("America/") || $0.hasPrefix("US/")) && !nonUnitedStatesAmericaIdentifiers.contains($0)
        })
    }()

    nonisolated private static func europeanCountry(for identifier: String) -> String? {
        switch identifier {
        case "Europe/Berlin": return "Germany"
        case "Europe/Paris": return "France"
        case "Europe/Rome": return "Italy"
        case "Europe/Madrid": return "Spain"
        case "Europe/Amsterdam": return "Netherlands"
        case "Europe/Brussels": return "Belgium"
        case "Europe/Vienna": return "Austria"
        case "Europe/Zurich": return "Switzerland"
        case "Europe/Stockholm": return "Sweden"
        case "Europe/Oslo": return "Norway"
        case "Europe/Copenhagen": return "Denmark"
        case "Europe/Helsinki": return "Finland"
        case "Europe/Warsaw": return "Poland"
        case "Europe/Prague": return "Czech Republic"
        case "Europe/Budapest": return "Hungary"
        case "Europe/Athens": return "Greece"
        case "Europe/Bucharest": return "Romania"
        case "Europe/Kiev", "Europe/Kyiv": return "Ukraine"
        case "Europe/Minsk": return "Belarus"
        default: return nil
        }
    }

    nonisolated private static func africanCountry(for identifier: String) -> String? {
        switch identifier {
        case "Africa/Cairo": return "Egypt"
        case "Africa/Johannesburg": return "South Africa"
        case "Africa/Lagos": return "Nigeria"
        case "Africa/Nairobi": return "Kenya"
        case "Africa/Casablanca": return "Morocco"
        default: return nil
        }
    }

    nonisolated private static func asianCountry(for identifier: String) -> String? {
        switch identifier {
        case "Asia/Shanghai": return "China"
        case "Asia/Urumqi": return "China"
        case "Asia/Ho_Chi_Minh": return "Vietnam"
        case "Asia/Vientiane": return "Laos"
        case "Asia/Phnom_Penh": return "Cambodia"
        case "Asia/Yangon": return "Myanmar"
        case "Asia/Almaty", "Asia/Qyzylorda", "Asia/Qostanay", "Asia/Aqtobe", "Asia/Aqtau", "Asia/Oral": return "Kazakhstan"
        case "Asia/Tashkent": return "Uzbekistan"
        case "Asia/Baku": return "Azerbaijan"
        case "Asia/Tbilisi": return "Georgia"
        case "Asia/Yerevan": return "Armenia"
        default: return nil
        }
    }

    nonisolated private static func pacificCountry(for identifier: String) -> String? {
        switch identifier {
        case "Pacific/Fiji": return "Fiji"
        case "Pacific/Tahiti", "Pacific/Marquesas", "Pacific/Gambier": return "French Polynesia"
        case "Pacific/Port_Moresby": return "Papua New Guinea"
        case "Pacific/Guadalcanal": return "Solomon Islands"
        case "Pacific/Tongatapu": return "Tonga"
        case "Pacific/Apia": return "Samoa"
        default: return nil
        }
    }

    nonisolated private static func americasCountry(for identifier: String) -> String? {
        if identifier.hasPrefix("America/Argentina") { return "Argentina" }
        if identifier.hasPrefix("America/Indiana") || identifier.hasPrefix("America/Kentucky")
            || identifier.hasPrefix("America/North_Dakota") { return "United States" }
        switch identifier {
        case "America/Sao_Paulo", "America/Rio_Branco", "America/Manaus", "America/Cuiaba",
             "America/Campo_Grande", "America/Porto_Velho", "America/Boa_Vista", "America/Eirunepe",
             "America/Fortaleza", "America/Recife", "America/Maceio", "America/Belem", "America/Santarem",
             "America/Araguaina", "America/Bahia", "America/Noronha": return "Brazil"
        case "America/Santiago", "America/Punta_Arenas": return "Chile"
        case "America/Bogota": return "Colombia"
        case "America/Lima": return "Peru"
        case "America/Caracas": return "Venezuela"
        case "America/La_Paz": return "Bolivia"
        case "America/Guayaquil": return "Ecuador"
        case "America/Montevideo": return "Uruguay"
        case "America/Asuncion": return "Paraguay"
        case "America/Havana": return "Cuba"
        case "America/Jamaica": return "Jamaica"
        case "America/Panama": return "Panama"
        case "America/Costa_Rica": return "Costa Rica"
        case "America/Guatemala": return "Guatemala"
        case "America/Tegucigalpa": return "Honduras"
        case "America/El_Salvador": return "El Salvador"
        case "America/Managua": return "Nicaragua"
        case "America/Puerto_Rico": return "Puerto Rico"
        default: return nil
        }
    }

    nonisolated private static func atlanticCountry(for identifier: String) -> String? {
        switch identifier {
        case "Atlantic/Bermuda": return "Bermuda"
        case "Atlantic/Reykjavik": return "Iceland"
        case "Atlantic/Azores": return "Portugal"
        case "Atlantic/Canary": return "Spain"
        case "Atlantic/Cape_Verde": return "Cape Verde"
        default: return nil
        }
    }

    nonisolated private static func indianOceanCountry(for identifier: String) -> String? {
        switch identifier {
        case "Indian/Maldives": return "Maldives"
        case "Indian/Mauritius": return "Mauritius"
        case "Indian/Reunion": return "Réunion"
        case "Indian/Seychelles": return "Seychelles"
        default: return nil
        }
    }
}
