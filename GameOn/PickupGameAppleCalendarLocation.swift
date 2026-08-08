import CoreLocation
import EventKit
import Foundation

/// Authoritative Apple Calendar location builder for FanGeo pickup games.
/// Source fields on ``PickupGameRow``: `address`, `city`, `state` (may include postal), `latitude`, `longitude`.
/// There is no persisted country / separate place-name column — do not invent missing data.
struct PickupGameAppleCalendarLocation: Equatable, Sendable {
    let placeName: String?
    let street: String?
    let city: String?
    let region: String?
    let postalCode: String?
    let country: String?
    let latitude: Double?
    let longitude: Double?

    /// Multi-line human-readable address for EventKit Location / structured title fallback.
    var displayAddress: String {
        var lines: [String] = []
        if let placeName, !placeName.isEmpty { lines.append(placeName) }
        if let street, !street.isEmpty { lines.append(street) }
        if let locality = localityLine, !locality.isEmpty { lines.append(locality) }
        if let country, !country.isEmpty { lines.append(country) }
        return lines.joined(separator: "\n")
    }

    /// Short label for Notes (not the full postal address).
    var notesVenueLabel: String {
        if let placeName, !placeName.isEmpty { return placeName }
        if let city, !city.isEmpty { return city }
        if let region, !region.isEmpty { return region }
        if let street, !street.isEmpty {
            if let first = street.split(separator: ",", maxSplits: 1).first {
                let segment = String(first).trimmingCharacters(in: .whitespacesAndNewlines)
                if !segment.isEmpty { return segment }
            }
            return street
        }
        return ""
    }

    /// Title for `EKStructuredLocation` — full readable address when available so Calendar Location shows it.
    var structuredTitle: String {
        let full = displayAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !full.isEmpty { return full }
        if let placeName, !placeName.isEmpty { return placeName }
        if let street, !street.isEmpty { return street }
        if let locality = localityLine, !locality.isEmpty { return locality }
        return ""
    }

    var hasUsableCoordinates: Bool {
        Self.isUsableCoordinate(latitude: latitude, longitude: longitude)
    }

    var localityLine: String? {
        Self.localityLine(city: city, region: region, postalCode: postalCode)
    }

    func makeStructuredLocation() -> EKStructuredLocation? {
        let title = structuredTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || hasUsableCoordinates else { return nil }

        let structured = EKStructuredLocation(title: title.isEmpty ? "Pickup game" : title)
        if hasUsableCoordinates, let latitude, let longitude {
            structured.geoLocation = CLLocation(latitude: latitude, longitude: longitude)
        }
        return structured
    }

    static func build(from game: PickupGameRow) -> PickupGameAppleCalendarLocation {
        let rawAddress = Self.normalize(game.address)
        let rawCity = Self.normalize(game.city)
        let rawState = Self.normalize(game.state)
        let regionPostal = Self.splitRegionAndPostal(rawState)

        var city = rawCity
        var region = regionPostal.region
        let postal = regionPostal.postalCode

        // Deduplicate city == region (e.g. "Riverton, Riverton").
        if Self.tokensEqual(city, region) {
            region = nil
        }

        let placeAndStreet = Self.classifyAddressLine(
            rawAddress,
            city: city,
            region: region,
            postalCode: postal
        )

        // If address embeds city/region, strip them from the place/street classification already handled.
        // Drop city when it only repeats the place name.
        if Self.tokensEqual(city, placeAndStreet.placeName) {
            city = nil
        }

        return PickupGameAppleCalendarLocation(
            placeName: placeAndStreet.placeName,
            street: placeAndStreet.street,
            city: city,
            region: region,
            postalCode: postal,
            country: nil,
            latitude: game.latitude,
            longitude: game.longitude
        )
    }

    // MARK: - Parsing / dedupe

    static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func tokensEqual(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    /// `state` column may store `"UT 84065"`, `"Utah 84065"`, or a bare region / city.
    static func splitRegionAndPostal(_ raw: String?) -> (region: String?, postalCode: String?) {
        guard let raw else { return (nil, nil) }
        let parts = raw
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return (nil, nil) }

        if parts.count >= 2, looksLikePostalCode(parts.last!) {
            let postal = parts.last!
            let region = parts.dropLast().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return (region.isEmpty ? nil : region, postal)
        }
        if parts.count == 1, looksLikePostalCode(parts[0]) {
            return (nil, parts[0])
        }
        return (raw, nil)
    }

    static func looksLikePostalCode(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 12 else { return false }
        // US ZIP / ZIP+4, Canada (A1A1A1 / A1A 1A1 collapsed), general alnum postal tokens with a digit.
        let compact = t.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
        guard compact.rangeOfCharacter(from: .decimalDigits) != nil else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return t.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Prefer treating digit-bearing lines as streets; otherwise as place names.
    static func classifyAddressLine(
        _ address: String?,
        city: String?,
        region: String?,
        postalCode: String?
    ) -> (placeName: String?, street: String?) {
        guard var line = address else { return (nil, nil) }

        // Strip trailing ", City" / ", Region" duplicates from the address field.
        for trailing in [city, region, postalCode].compactMap({ $0 }) {
            line = stripTrailingComponent(line, matching: trailing)
        }

        let cleaned = normalize(line)
        guard let cleaned else { return (nil, nil) }

        let hasStreetNumber = cleaned.range(of: #"\d"#, options: .regularExpression) != nil
        if hasStreetNumber {
            return (nil, cleaned)
        }
        return (cleaned, nil)
    }

    static func stripTrailingComponent(_ line: String, matching component: String) -> String {
        let trimmedComponent = component.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedComponent.isEmpty else { return line }
        var result = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixes = [
            ", \(trimmedComponent)",
            " · \(trimmedComponent)",
            " - \(trimmedComponent)"
        ]
        for suffix in suffixes {
            if result.count > suffix.count,
               result.suffix(suffix.count).compare(suffix, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                result = String(result.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if tokensEqual(result, trimmedComponent) {
            return ""
        }
        return result
    }

    static func localityLine(city: String?, region: String?, postalCode: String?) -> String? {
        let c = normalize(city)
        let r = normalize(region)
        let p = normalize(postalCode)

        // City + postal, no region: prefer postal-first (common in FR/EU), e.g. "75015 Paris".
        if let c, r == nil, let p {
            return "\(p) \(c)"
        }

        let locality: String?
        if let c, let r, !tokensEqual(c, r) {
            locality = "\(c), \(r)"
        } else {
            locality = c ?? r
        }

        switch (locality, p) {
        case let (loc?, zip?):
            return "\(loc) \(zip)"
        case let (loc?, nil):
            return loc
        case let (nil, zip?):
            return zip
        case (nil, nil):
            return nil
        }
    }

    static func isUsableCoordinate(latitude: Double?, longitude: Double?) -> Bool {
        guard let latitude, let longitude else { return false }
        guard latitude.isFinite, longitude.isFinite else { return false }
        guard abs(latitude) <= 90, abs(longitude) <= 180 else { return false }
        // Reject null-island placeholders unless we somehow have a real 0,0 venue (extremely rare).
        if abs(latitude) < 0.000_01, abs(longitude) < 0.000_01 { return false }
        return CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
    }
}
