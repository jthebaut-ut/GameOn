import CoreLocation
import Foundation

/// Presentation-only classifier for Match Details “Where It’s Played”.
/// Keeps competition country separate from stadium / city / street match location.
nonisolated enum LiveMatchPlayedLocationPresentation {
    struct Resolved: Sendable {
        /// Real stadium / venue name or street when specific (never country-only).
        let primaryTitle: String?
        /// Supporting locality, e.g. "Seaside, California, United States".
        let localityLine: String?
        /// Pin title when opening coordinates.
        let mapTitle: String
        let coordinate: CLLocationCoordinate2D?
        /// Specific Apple Maps search query when coordinates are unavailable.
        let mapsSearchQuery: String?

        var hasCoordinates: Bool { coordinate != nil }
        var canOpenMaps: Bool { hasCoordinates || !(mapsSearchQuery?.isEmpty ?? true) }
    }

    /// Returns a resolved location only when the match has meaningful, specific place data.
    static func resolve(
        venueName: String?,
        venueCity: String?,
        leagueCountry: String?,
        coordinate: CLLocationCoordinate2D?,
        localizedCountryName: String?
    ) -> Resolved? {
        let rawName = cleaned(venueName)
        let rawCityBlob = cleaned(venueCity)
        let competitionCountry = cleaned(leagueCountry)
        let localizedCountry = cleaned(localizedCountryName)
        let countryDisplay = localizedCountry.isEmpty ? competitionCountry : localizedCountry

        let stadium = meaningfulVenueName(rawName)

        let parsedCityBlob = parseCityBlob(rawCityBlob)
        let street: String? = {
            if looksLikeStreetAddress(rawName) { return rawName }
            return parsedCityBlob.street
        }()

        let specificCity = meaningfulCity(parsedCityBlob.city)
        let specificRegion = meaningfulRegion(parsedCityBlob.region)

        let hasCoords = coordinate != nil
        let hasStadium = stadium != nil
        let hasStreet = street != nil
        let hasCityWithCoords = specificCity != nil && hasCoords
        let hasCoordsWithTitle = hasCoords && (hasStadium || hasStreet || specificCity != nil)

        // Strict section gate — country / region alone never qualifies.
        guard hasStadium || hasStreet || hasCityWithCoords || hasCoordsWithTitle else {
            return nil
        }

        let primary = stadium ?? street
        let locality = localityLine(
            city: specificCity,
            region: specificRegion,
            countryDisplay: countryDisplay,
            includeCountry: specificCity != nil || specificRegion != nil || primary != nil
        )

        let mapTitle = primary ?? specificCity ?? "Location"

        let searchQuery: String? = {
            if hasCoords { return nil }
            if let primary, specificCity != nil || specificRegion != nil || !countryDisplay.isEmpty {
                return joinedSearch([primary, specificCity, specificRegion, countryDisplay])
            }
            if let street {
                return joinedSearch([street, specificCity, specificRegion, countryDisplay])
            }
            return nil
        }()

        return Resolved(
            primaryTitle: primary,
            localityLine: locality,
            mapTitle: mapTitle,
            coordinate: coordinate,
            mapsSearchQuery: searchQuery
        )
    }

    // MARK: - Classification

    static func cleaned(_ raw: String?) -> String {
        (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    static func normalizedKey(_ raw: String) -> String {
        cleaned(raw)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    static func isGenericOrNonSpecific(_ raw: String) -> Bool {
        let key = normalizedKey(raw)
        guard !key.isEmpty else { return true }

        let rejected: Set<String> = [
            "unknown",
            "unknown venue",
            "unknown stadium",
            "unknown location",
            "tbd",
            "tba",
            "tbc",
            "n/a",
            "na",
            "none",
            "null",
            "neutral",
            "neutral venue",
            "neutral ground",
            "neutral site",
            "home",
            "home venue",
            "home stadium",
            "away",
            "away venue",
            "stadium",
            "venue",
            "arena",
            "ground"
        ]
        if rejected.contains(key) { return true }
        if key.hasPrefix("unknown ") { return true }
        if key.hasPrefix("tbd") || key.hasPrefix("tba") || key.hasPrefix("tbc") { return true }
        return false
    }

    /// True when the string is only a country name / country code.
    static func isCountryOnlyText(_ raw: String) -> Bool {
        let trimmed = cleaned(raw)
        guard !trimmed.isEmpty else { return false }
        if CountryFlagHelper.isCountry(trimmed) { return true }
        if CountryFlagHelper.countryCode(for: trimmed) != nil {
            let lettersOnly = trimmed.filter(\.isLetter)
            if lettersOnly.count >= 2, lettersOnly.count <= 3, lettersOnly.count == trimmed.filter({ !$0.isWhitespace && $0 != "." }).count {
                return true
            }
        }
        return false
    }

    static func meaningfulVenueName(_ raw: String) -> String? {
        let trimmed = cleaned(raw)
        guard !trimmed.isEmpty else { return nil }
        guard !isGenericOrNonSpecific(trimmed) else { return nil }
        guard !isCountryOnlyText(trimmed) else { return nil }
        if isBroadRegionOnly(trimmed) { return nil }
        if looksLikeStreetAddress(trimmed) { return nil } // street handled separately
        return trimmed
    }

    static func meaningfulCity(_ raw: String) -> String? {
        let trimmed = cleaned(raw)
        guard !trimmed.isEmpty else { return nil }
        guard !isGenericOrNonSpecific(trimmed) else { return nil }
        guard !isCountryOnlyText(trimmed) else { return nil }
        guard !isBroadRegionOnly(trimmed) else { return nil }
        return trimmed
    }

    static func meaningfulRegion(_ raw: String) -> String? {
        let trimmed = cleaned(raw)
        guard !trimmed.isEmpty else { return nil }
        guard !isGenericOrNonSpecific(trimmed) else { return nil }
        guard !isCountryOnlyText(trimmed) else { return nil }
        return trimmed
    }

    /// Administrative areas / continents used alone are not specific match locations.
    static func isBroadRegionOnly(_ raw: String) -> Bool {
        let key = normalizedKey(raw)
        let regions: Set<String> = [
            "california", "ca", "new york", "ny", "texas", "tx", "florida", "fl",
            "illinois", "il", "ohio", "pennsylvania", "pa", "georgia", "ga",
            "arizona", "az", "colorado", "co", "washington", "wa", "oregon", "or",
            "nevada", "nv", "utah", "ut", "massachusetts", "ma", "new jersey", "nj",
            "michigan", "mi", "north carolina", "south carolina", "virginia", "va",
            "maryland", "md", "missouri", "mo", "tennessee", "tn", "indiana", "in",
            "wisconsin", "wi", "minnesota", "mn", "alabama", "al", "louisiana", "la",
            "kentucky", "ky", "oklahoma", "ok", "connecticut", "ct", "iowa", "ia",
            "kansas", "ks", "arkansas", "ar", "mississippi", "ms", "nebraska", "ne",
            "new mexico", "nm", "hawaii", "hi", "idaho", "id", "maine", "me",
            "montana", "mt", "rhode island", "ri", "delaware", "de", "south dakota",
            "north dakota", "alaska", "ak", "vermont", "vt", "wyoming", "wy",
            "west virginia", "district of columbia", "dc", "puerto rico", "pr",
            "ontario", "quebec", "british columbia", "alberta", "manitoba",
            "saskatchewan", "nova scotia", "new brunswick",
            "england", "scotland", "wales", "northern ireland",
            "europe", "north america", "south america", "asia", "africa", "oceania"
        ]
        return regions.contains(key)
    }

    static func looksLikeStreetAddress(_ raw: String) -> Bool {
        let trimmed = cleaned(raw)
        guard !trimmed.isEmpty else { return false }
        guard !isGenericOrNonSpecific(trimmed) else { return false }
        guard !isCountryOnlyText(trimmed) else { return false }
        return trimmed.rangeOfCharacter(from: .decimalDigits) != nil
    }

    /// Parses provider city blobs into optional street / city / region.
    static func parseCityBlob(_ raw: String) -> (street: String?, city: String, region: String) {
        let trimmed = cleaned(raw)
        guard !trimmed.isEmpty else { return (nil, "", "") }
        let parts = trimmed
            .split(separator: ",")
            .map { cleaned(String($0)) }
            .filter { !$0.isEmpty }

        if let first = parts.first, looksLikeStreetAddress(first) {
            let street = first
            if parts.count >= 3 {
                return (street, parts[1], parts.dropFirst(2).joined(separator: ", "))
            }
            if parts.count == 2 {
                return (street, parts[1], "")
            }
            return (street, "", "")
        }

        if parts.count >= 2 {
            return (nil, parts[0], parts.dropFirst().joined(separator: ", "))
        }
        return (nil, trimmed, "")
    }

    private static func localityLine(
        city: String?,
        region: String?,
        countryDisplay: String,
        includeCountry: Bool
    ) -> String? {
        var parts: [String] = []
        if let city, !city.isEmpty { parts.append(city) }
        if let region, !region.isEmpty { parts.append(region) }
        if includeCountry, !countryDisplay.isEmpty, !isGenericOrNonSpecific(countryDisplay) {
            let countryKey = normalizedKey(countryDisplay)
            if !parts.contains(where: { normalizedKey($0) == countryKey }) {
                parts.append(countryDisplay)
            }
        }
        guard !parts.isEmpty else { return nil }
        if parts.count == 1, isCountryOnlyText(parts[0]) { return nil }
        if parts.count == 1, isBroadRegionOnly(parts[0]) { return nil }
        return parts.joined(separator: ", ")
    }

    private static func joinedSearch(_ parts: [String?]) -> String? {
        let values = parts
            .compactMap { $0.map(cleaned) }
            .filter { !$0.isEmpty }
        guard !values.isEmpty else { return nil }
        if values.count == 1, isCountryOnlyText(values[0]) || isBroadRegionOnly(values[0]) {
            return nil
        }
        if values.allSatisfy({ isCountryOnlyText($0) || isBroadRegionOnly($0) }) {
            return nil
        }
        return values.joined(separator: ", ")
    }
}

#if DEBUG
enum LiveMatchPlayedLocationPresentationSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ name: String, _ condition: Bool) {
            if condition {
                print("[LiveMatchPlayedLocationTest] PASS \(name)")
            } else {
                failures += 1
                print("[LiveMatchPlayedLocationTest] FAIL \(name)")
            }
        }

        expect(
            "E_country_only_hidden",
            LiveMatchPlayedLocationPresentation.resolve(
                venueName: nil,
                venueCity: nil,
                leagueCountry: "United States",
                coordinate: nil,
                localizedCountryName: "United States"
            ) == nil
        )

        expect(
            "F_unknown_venue_hidden",
            LiveMatchPlayedLocationPresentation.resolve(
                venueName: "Unknown venue",
                venueCity: "United States",
                leagueCountry: "United States",
                coordinate: nil,
                localizedCountryName: "United States"
            ) == nil
        )

        let stadiumCity = LiveMatchPlayedLocationPresentation.resolve(
            venueName: "Cardinale Stadium",
            venueCity: "Seaside, California",
            leagueCountry: "United States",
            coordinate: nil,
            localizedCountryName: "United States"
        )
        expect("B_stadium_city_shown", stadiumCity != nil)
        expect("B_stadium_title", stadiumCity?.primaryTitle == "Cardinale Stadium")
        expect("B_maps_search", stadiumCity?.mapsSearchQuery?.contains("Cardinale Stadium") == true)
        expect("B_locality_has_city", stadiumCity?.localityLine?.contains("Seaside") == true)
        expect("B_locality_not_country_alone", stadiumCity?.localityLine != "United States")

        let coords = CLLocationCoordinate2D(latitude: 36.624, longitude: -121.84)
        let stadiumCoords = LiveMatchPlayedLocationPresentation.resolve(
            venueName: "Cardinale Stadium",
            venueCity: "Seaside, California",
            leagueCountry: "United States",
            coordinate: coords,
            localizedCountryName: "United States"
        )
        expect("A_full_section", stadiumCoords?.hasCoordinates == true)
        expect("A_can_open_maps", stadiumCoords?.canOpenMaps == true)

        expect(
            "D_city_plus_coords",
            LiveMatchPlayedLocationPresentation.resolve(
                venueName: nil,
                venueCity: "Seaside",
                leagueCountry: "United States",
                coordinate: coords,
                localizedCountryName: "United States"
            ) != nil
        )

        expect(
            "city_only_no_coords_hidden",
            LiveMatchPlayedLocationPresentation.resolve(
                venueName: nil,
                venueCity: "Seaside",
                leagueCountry: "United States",
                coordinate: nil,
                localizedCountryName: "United States"
            ) == nil
        )

        expect(
            "region_only_hidden",
            LiveMatchPlayedLocationPresentation.resolve(
                venueName: nil,
                venueCity: "California",
                leagueCountry: "United States",
                coordinate: nil,
                localizedCountryName: "United States"
            ) == nil
        )

        let street = LiveMatchPlayedLocationPresentation.resolve(
            venueName: "1 E 161st Street",
            venueCity: "Bronx, New York",
            leagueCountry: "United States",
            coordinate: nil,
            localizedCountryName: "United States"
        )
        expect("C_street_address", street != nil)
        expect("C_street_maps", street?.canOpenMaps == true)

        if failures == 0 {
            print("[LiveMatchPlayedLocationTest] ALL PASSED")
        } else {
            print("[LiveMatchPlayedLocationTest] FAILURES=\(failures)")
        }
    }
}
#endif
