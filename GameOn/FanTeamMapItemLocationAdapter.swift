import CoreLocation
import Foundation
import MapKit

/// Converts an `MKMapItem` into the Team Schedule location contract without touching UI.
///
/// iOS 26+ uses `location` / `address` / `addressRepresentations` / `name` / `identifier`.
/// Legacy `MKMapItem.placemark` is intentionally never referenced — FanGeo’s deployment
/// target is already iOS 26+, and calling `placemark` (even in a dead `#available` else)
/// reintroduces the iOS 26 deprecation warnings this adapter exists to remove.
nonisolated enum FanTeamMapItemLocationAdapter {
    /// Builds a `FanTeamLocationSelection` from a MapKit search / map item.
    static func selection(from mapItem: MKMapItem) -> FanTeamLocationSelection? {
        if #available(iOS 26.0, *) {
            return selectionUsingModernMapKit(from: mapItem)
        }
        // Pre-iOS 26 branch kept for shape only (inactive while DT >= 26).
        return selectionUsingLocationAndNameOnly(from: mapItem)
    }

    // MARK: - iOS 26+

    @available(iOS 26.0, *)
    private static func selectionUsingModernMapKit(from mapItem: MKMapItem) -> FanTeamLocationSelection? {
        let coordinate = mapItem.location.coordinate
        guard isUsableCoordinate(coordinate) else { return nil }

        let representations = mapItem.addressRepresentations
        let fields = parseAddressComponents(
            placeName: mapItem.name,
            shortAddress: mapItem.address?.shortAddress,
            fullAddressSingleLine: representations?.fullAddress(includingRegion: false, singleLine: true)
                ?? mapItem.address?.fullAddress,
            fullAddressMultiline: representations?.fullAddress(includingRegion: false, singleLine: false)
                ?? mapItem.address?.fullAddress,
            cityName: representations?.cityName,
            cityWithContext: representations?.cityWithContext,
            countryCode: countryCode(from: representations)
        )

        return FanTeamLocationSelection(
            teamLocationId: nil,
            nickname: nil,
            placeName: fields.placeName,
            address: fields.address,
            city: fields.city,
            state: fields.state,
            zipCode: fields.zipCode,
            countryCode: fields.countryCode,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            providerPlaceId: providerPlaceId(from: mapItem)
        )
    }

    /// Fallback that never touches deprecated placemark APIs.
    private static func selectionUsingLocationAndNameOnly(from mapItem: MKMapItem) -> FanTeamLocationSelection? {
        let coordinate = mapItem.location.coordinate
        guard isUsableCoordinate(coordinate) else { return nil }
        let place = trimmedNonEmpty(mapItem.name)
        return FanTeamLocationSelection(
            teamLocationId: nil,
            nickname: nil,
            placeName: place,
            address: place ?? "",
            city: "",
            state: "",
            zipCode: "",
            countryCode: "",
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            providerPlaceId: providerPlaceId(from: mapItem)
        )
    }

    private static func providerPlaceId(from mapItem: MKMapItem) -> String? {
        mapItem.identifier.map(\.rawValue)
    }

    private static func isUsableCoordinate(_ coordinate: CLLocationCoordinate2D) -> Bool {
        CLLocationCoordinate2DIsValid(coordinate)
            && coordinate.latitude.isFinite
            && coordinate.longitude.isFinite
            && abs(coordinate.latitude) <= 90
            && abs(coordinate.longitude) <= 180
            && !(coordinate.latitude == 0 && coordinate.longitude == 0)
    }

    // MARK: - Pure address parsing (testable without MapKit network)

    struct ParsedAddressFields: Equatable, Sendable {
        var placeName: String?
        var address: String
        var city: String
        var state: String
        var zipCode: String
        /// ISO 3166-1 alpha-2 when known from MapKit; empty when unknown.
        var countryCode: String
    }

    /// Maps modern MapKit address strings into FanGeo’s street / city / state / zip / country fields.
    /// Keeps street separate from locality so `FanTeamLocation.addressLine` does not duplicate
    /// "Draper, UT" when concatenating address + locality.
    static func parseAddressComponents(
        placeName: String?,
        shortAddress: String?,
        fullAddressSingleLine: String?,
        fullAddressMultiline: String?,
        cityName: String?,
        cityWithContext: String?,
        countryCode: String? = nil
    ) -> ParsedAddressFields {
        let city = trimmedNonEmpty(cityName) ?? ""
        // Prefer newline-separated MapKit lines (matches existing FanGeo geocode helpers).
        // Do not split on commas — suite / unit text can contain them.
        let multiline = addressLines(from: fullAddressMultiline)
        let lines = multiline.isEmpty ? addressLines(from: fullAddressSingleLine) : multiline

        let statePostal = stateAndPostalCode(from: lines, city: optionalNonEmpty(city))
        let stateFromContext = stateAbbreviation(from: cityWithContext, city: optionalNonEmpty(city))
        let state = stateFromContext ?? statePostal.state ?? ""
        let zip = statePostal.postalCode ?? ""
        let country = BusinessLocationCountryPolicy.normalizedStoredCountryCode(countryCode ?? "")

        // Prefer a dedicated street line, then shortAddress, then a stripped single-line full address.
        let streetCandidate = streetLine(from: lines, city: optionalNonEmpty(city))
            ?? streetFromShortAddress(shortAddress, city: city, state: state, zip: zip)
            ?? stripTrailingLocality(
                from: trimmedNonEmpty(fullAddressSingleLine) ?? "",
                city: city,
                state: state,
                zip: zip
            )

        let normalizedStreet = stripTrailingLocality(
            from: streetCandidate,
            city: city,
            state: state,
            zip: zip
        )

        let place: String?
        if let name = trimmedNonEmpty(placeName) {
            if name.caseInsensitiveCompare(normalizedStreet) == .orderedSame {
                place = nil
            } else if !city.isEmpty, name.caseInsensitiveCompare(city) == .orderedSame {
                place = nil
            } else {
                place = name
            }
        } else {
            place = nil
        }

        return ParsedAddressFields(
            placeName: place,
            address: normalizedStreet,
            city: city,
            state: state,
            zipCode: zip,
            countryCode: country
        )
    }

    /// Display helper used by tests — worldwide when country is known.
    static func composedAddressLine(fields: ParsedAddressFields) -> String {
        let formatted = FanTeamLocationPresentation.formattedAddress(
            placeName: fields.placeName,
            street: fields.address,
            city: fields.city,
            region: fields.state,
            postalCode: fields.zipCode,
            countryCode: fields.countryCode
        )
        if !formatted.isEmpty { return formatted }
        var parts: [String] = []
        let street = fields.address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !street.isEmpty { parts.append(street) }
        let locality = FanTeamLocationPresentation.localityLine(
            city: fields.city,
            region: fields.state,
            postalCode: fields.zipCode,
            countryCode: fields.countryCode
        )
        if !locality.isEmpty {
            let alreadyHasLocality = street.localizedCaseInsensitiveContains(locality)
            if !alreadyHasLocality {
                parts.append(locality)
            }
        }
        return parts.joined(separator: ", ")
    }

    @available(iOS 26.0, *)
    private static func countryCode(from representations: MKAddressRepresentations?) -> String? {
        guard let representations else { return nil }
        if let regionIdentifier = trimmedNonEmpty(representations.region?.identifier) {
            let code = BusinessLocationCountryPolicy.normalizedStoredCountryCode(regionIdentifier)
            return code.isEmpty ? nil : code
        }
        if let name = trimmedNonEmpty(representations.regionName) {
            return BusinessLocationCountryPolicy.supportedCountryChoices.first {
                $0.label.caseInsensitiveCompare(name) == .orderedSame
            }?.code
        }
        return nil
    }

    // MARK: - Parsing primitives

    private static func addressLines(from raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func streetLine(from lines: [String], city: String?) -> String? {
        guard let city, !city.isEmpty else { return lines.first }
        if let street = lines.first(where: { line in
            !isCityStatePostalLine(line, city: city)
        }) {
            return street
        }
        return nil
    }

    private static func isCityStatePostalLine(_ line: String, city: String) -> Bool {
        guard line.localizedCaseInsensitiveContains(city) else { return false }
        // "Draper, UT 84020" or bare "Draper"
        if line.caseInsensitiveCompare(city) == .orderedSame { return true }
        guard line.contains(",") else { return false }
        let remainder = line.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true)
        guard remainder.count == 2 else { return false }
        let left = remainder[0].trimmingCharacters(in: .whitespacesAndNewlines)
        return left.caseInsensitiveCompare(city) == .orderedSame
    }

    private static func streetFromShortAddress(
        _ shortAddress: String?,
        city: String,
        state: String,
        zip: String
    ) -> String? {
        guard let short = trimmedNonEmpty(shortAddress) else { return nil }
        let stripped = stripTrailingLocality(from: short, city: city, state: state, zip: zip)
        return stripped.isEmpty ? nil : stripped
    }

    private static func stripTrailingLocality(
        from street: String,
        city: String,
        state: String,
        zip: String
    ) -> String {
        var result = street.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }

        var localityCandidates: [String] = []
        if !city.isEmpty, !state.isEmpty, !zip.isEmpty {
            localityCandidates.append("\(city), \(state) \(zip)")
        }
        if !city.isEmpty, !state.isEmpty {
            localityCandidates.append("\(city), \(state)")
        }
        if !city.isEmpty {
            localityCandidates.append(city)
        }

        for candidate in localityCandidates {
            if let range = result.range(of: candidate, options: [.caseInsensitive, .backwards]),
               range.upperBound == result.endIndex {
                result = String(result[..<range.lowerBound])
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
                break
            }
        }
        return result
    }

    private static func stateAbbreviation(from cityContext: String?, city: String?) -> String? {
        guard
            let cityContext = trimmedNonEmpty(cityContext),
            let city,
            cityContext.localizedCaseInsensitiveContains(city),
            let commaIndex = cityContext.firstIndex(of: ",")
        else {
            return nil
        }
        let remainder = cityContext[cityContext.index(after: commaIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let token = remainder.split(separator: ",").first.map(String.init) ?? ""
        let stateToken = token.split(separator: " ").first.map(String.init) ?? token
        return trimmedNonEmpty(stateToken)
    }

    private static func stateAndPostalCode(from lines: [String], city: String?) -> (state: String?, postalCode: String?) {
        guard let city, !city.isEmpty else { return (nil, nil) }

        if let cityLine = lines.first(where: { isCityStatePostalLine($0, city: city) }) {
            // Bare "Springfield" has no state/zip — do not invent state from the city token.
            if cityLine.caseInsensitiveCompare(city) == .orderedSame {
                return (nil, nil)
            }
            return parseStatePostalSuffix(cityLine, afterFirstComma: true)
        }

        // Single-line full addresses: "5032 N Shady Bend Ln, Draper, UT 84020"
        if let line = lines.first(where: { $0.localizedCaseInsensitiveContains(city) }),
           let cityRange = line.range(of: city, options: [.caseInsensitive]) {
            let afterCity = line[cityRange.upperBound...]
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
            return parseStatePostalTokens(afterCity)
        }

        return (nil, nil)
    }

    private static func parseStatePostalSuffix(_ line: String, afterFirstComma: Bool) -> (state: String?, postalCode: String?) {
        guard afterFirstComma, let commaIndex = line.firstIndex(of: ",") else {
            return parseStatePostalTokens(line)
        }
        let suffix = line[line.index(after: commaIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return parseStatePostalTokens(suffix)
    }

    private static func parseStatePostalTokens(_ raw: String) -> (state: String?, postalCode: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, nil) }
        let pieces = trimmed
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .map {
                $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
            }
            .filter { !$0.isEmpty }
        let state = pieces.first.flatMap { trimmedNonEmpty($0) }
        let postal = pieces.dropFirst().first.flatMap { trimmedNonEmpty($0) }
        return (state, postal)
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func optionalNonEmpty(_ value: String) -> String? {
        trimmedNonEmpty(value)
    }
}
