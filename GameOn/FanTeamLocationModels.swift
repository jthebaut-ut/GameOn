import CoreLocation
import Foundation

// MARK: - Debug

enum TeamLocationDebug {
    static func log(_ event: String, detail: String? = nil) {
#if DEBUG
        if let detail, !detail.isEmpty {
            print("[TeamLocation] \(event) \(detail)")
        } else {
            print("[TeamLocation] \(event)")
        }
#endif
    }
}

// MARK: - Canonical selection applied to schedule draft

/// Mirrors the address/city/state/lat/lon fields already persisted on `pickup_games`,
/// plus Team-location postal/country structured fields.
/// Nickname is Team-only presentation metadata and is never written to the event row.
///
/// `nonisolated` so MapKit adapters / background parsing can build selections without
/// hopping onto the main actor (module default isolation is MainActor).
nonisolated struct FanTeamLocationSelection: Equatable, Sendable {
    var teamLocationId: UUID?
    var nickname: String?
    var placeName: String?
    var address: String
    var city: String
    var state: String
    var zipCode: String
    /// ISO 3166-1 alpha-2 (e.g. `US`, `GB`). Empty when unknown/legacy.
    var countryCode: String
    var latitude: Double
    var longitude: Double
    var providerPlaceId: String?

    init(
        teamLocationId: UUID? = nil,
        nickname: String? = nil,
        placeName: String? = nil,
        address: String,
        city: String,
        state: String,
        zipCode: String,
        countryCode: String = "",
        latitude: Double,
        longitude: Double,
        providerPlaceId: String? = nil
    ) {
        self.teamLocationId = teamLocationId
        self.nickname = nickname
        self.placeName = placeName
        self.address = address
        self.city = city
        self.state = state
        self.zipCode = zipCode
        self.countryCode = BusinessLocationCountryPolicy.normalizedStoredCountryCode(countryCode)
        self.latitude = latitude
        self.longitude = longitude
        self.providerPlaceId = providerPlaceId
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var hasValidCoordinate: Bool {
        latitude.isFinite
            && longitude.isFinite
            && abs(latitude) <= 90
            && abs(longitude) <= 180
            && !(latitude == 0 && longitude == 0)
    }

    /// Street-first display line used by the schedule form summary.
    var primaryDisplayLine: String {
        let nick = nickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !nick.isEmpty { return nick }
        let place = placeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !place.isEmpty { return place }
        let street = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !street.isEmpty { return street }
        return localityLine
    }

    var localityLine: String {
        FanTeamLocationPresentation.localityLine(
            city: city,
            region: state,
            postalCode: zipCode,
            countryCode: countryCode
        )
    }

    /// Multi-line / comma display suitable worldwide (not US-only City, ST ZIP).
    var displayAddressLine: String {
        FanTeamLocationPresentation.formattedAddress(
            placeName: placeName,
            street: address,
            city: city,
            region: state,
            postalCode: zipCode,
            countryCode: countryCode
        )
    }

    /// Address line persisted on the pickup game (`address` column).
    var persistableAddress: String {
        let street = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !street.isEmpty { return street }
        return placeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Query string for forward geocoding (includes country context when known).
    var geocodeQuery: String {
        BusinessVenueAddressFormatter.geocodeQuery(
            line1: persistableAddress.isEmpty ? (placeName ?? "") : persistableAddress,
            locality: city,
            region: state,
            postalCode: zipCode,
            countryCode: countryCode
        )
    }
}

// MARK: - Persisted Team location row

struct FanTeamLocation: Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let teamId: UUID
    let nickname: String?
    let placeName: String?
    let address: String?
    let city: String?
    let state: String?
    let postalCode: String?
    /// ISO 3166-1 alpha-2 when known; nil/empty for legacy rows.
    let countryCode: String?
    let latitude: Double?
    let longitude: Double?
    let providerPlaceId: String?
    let identityKey: String
    let isSaved: Bool
    let isDefault: Bool
    let usageCount: Int
    let lastUsedAt: Date?
    let createdBy: UUID?
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case teamId = "team_id"
        case nickname
        case placeName = "place_name"
        case address
        case city
        case state
        case postalCode = "postal_code"
        case countryCode = "country_code"
        case latitude
        case longitude
        case providerPlaceId = "provider_place_id"
        case identityKey = "identity_key"
        case isSaved = "is_saved"
        case isDefault = "is_default"
        case usageCount = "usage_count"
        case lastUsedAt = "last_used_at"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

extension FanTeamLocation: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        teamId = try c.decode(UUID.self, forKey: .teamId)
        nickname = try Self.trimOptional(c.decodeIfPresent(String.self, forKey: .nickname))
        placeName = try Self.trimOptional(c.decodeIfPresent(String.self, forKey: .placeName))
        address = try Self.trimOptional(c.decodeIfPresent(String.self, forKey: .address))
        city = try Self.trimOptional(c.decodeIfPresent(String.self, forKey: .city))
        state = try Self.trimOptional(c.decodeIfPresent(String.self, forKey: .state))
        postalCode = try Self.trimOptional(c.decodeIfPresent(String.self, forKey: .postalCode))
        if let rawCountry = try Self.trimOptional(c.decodeIfPresent(String.self, forKey: .countryCode)) {
            let normalized = BusinessLocationCountryPolicy.normalizedStoredCountryCode(rawCountry)
            countryCode = normalized.isEmpty ? nil : normalized
        } else {
            countryCode = nil
        }
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        providerPlaceId = try Self.trimOptional(c.decodeIfPresent(String.self, forKey: .providerPlaceId))
        identityKey = try c.decode(String.self, forKey: .identityKey)
        isSaved = try c.decodeIfPresent(Bool.self, forKey: .isSaved) ?? false
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        usageCount = try c.decodeIfPresent(Int.self, forKey: .usageCount) ?? 0
        lastUsedAt = try Self.decodeOptionalDate(c, key: .lastUsedAt)
        createdBy = try c.decodeIfPresent(UUID.self, forKey: .createdBy)
        createdAt = try Self.decodeDate(c, key: .createdAt) ?? Date()
        updatedAt = try Self.decodeDate(c, key: .updatedAt) ?? createdAt
    }

    private static func trimOptional(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func decodeDate(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> Date? {
        if let date = try c.decodeIfPresent(Date.self, forKey: key) { return date }
        if let raw = try c.decodeIfPresent(String.self, forKey: key) {
            return PickupGameModels.parseSupabaseTimestamptz(raw)
        }
        return nil
    }

    private static func decodeOptionalDate(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> Date? {
        try decodeDate(c, key: key)
    }

    var title: String {
        if let nickname, !nickname.isEmpty { return nickname }
        if let placeName, !placeName.isEmpty { return placeName }
        if let address, !address.isEmpty { return address }
        return localityLine
    }

    var subtitlePlace: String? {
        if nickname != nil, let placeName, !placeName.isEmpty { return placeName }
        return nil
    }

    var localityLine: String {
        FanTeamLocationPresentation.localityLine(
            city: city ?? "",
            region: state ?? "",
            postalCode: postalCode ?? "",
            countryCode: countryCode ?? ""
        )
    }

    var addressLine: String {
        FanTeamLocationPresentation.formattedAddress(
            placeName: nil,
            street: address,
            city: city ?? "",
            region: state ?? "",
            postalCode: postalCode ?? "",
            countryCode: countryCode ?? ""
        )
    }

    var selection: FanTeamLocationSelection? {
        guard let latitude, let longitude else { return nil }
        let sel = FanTeamLocationSelection(
            teamLocationId: id,
            nickname: nickname,
            placeName: placeName,
            address: address ?? "",
            city: city ?? "",
            state: state ?? "",
            zipCode: postalCode ?? "",
            countryCode: countryCode ?? "",
            latitude: latitude,
            longitude: longitude,
            providerPlaceId: providerPlaceId
        )
        guard sel.hasValidCoordinate else { return nil }
        return sel
    }

    /// Test / preview factory (Decodable still owns production decoding).
    static func stub(
        id: UUID = UUID(),
        teamId: UUID = UUID(),
        nickname: String? = nil,
        placeName: String? = nil,
        address: String? = nil,
        city: String? = nil,
        state: String? = nil,
        postalCode: String? = nil,
        countryCode: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        providerPlaceId: String? = nil,
        identityKey: String = "test",
        isSaved: Bool = false,
        isDefault: Bool = false,
        usageCount: Int = 0,
        lastUsedAt: Date? = nil,
        createdBy: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) -> FanTeamLocation {
        FanTeamLocation(
            id: id,
            teamId: teamId,
            nickname: nickname,
            placeName: placeName,
            address: address,
            city: city,
            state: state,
            postalCode: postalCode,
            countryCode: countryCode,
            latitude: latitude,
            longitude: longitude,
            providerPlaceId: providerPlaceId,
            identityKey: identityKey,
            isSaved: isSaved,
            isDefault: isDefault,
            usageCount: usageCount,
            lastUsedAt: lastUsedAt,
            createdBy: createdBy,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

// MARK: - Presentation helpers

enum FanTeamLocationPresentation {
    /// Compact locality line (city / region / postal) without country name.
    /// Pure formatting — safe off the main actor for MapKit adapters / tests.
    nonisolated static func localityLine(
        city: String,
        region: String,
        postalCode: String = "",
        countryCode: String = ""
    ) -> String {
        let c = city.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = region.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = postalCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = BusinessLocationCountryPolicy.normalizedStoredCountryCode(countryCode)

        // Europe-style: postal precedes city when both present.
        if !code.isEmpty, europeStyleCountryCodes.contains(code) {
            let cityLine = [p, c].filter { !$0.isEmpty }.joined(separator: " ")
            return [cityLine, r].filter { !$0.isEmpty }.joined(separator: ", ")
        }

        let regionPostal = [r, p].filter { !$0.isEmpty }.joined(separator: " ")
        switch (c.isEmpty, regionPostal.isEmpty) {
        case (false, false): return "\(c), \(regionPostal)"
        case (false, true): return c
        case (true, false): return regionPostal
        case (true, true): return ""
        }
    }

    /// Worldwide display using the same formatter as business venues (ISO country code).
    /// Pure formatting — safe off the main actor for MapKit adapters / tests.
    nonisolated static func formattedAddress(
        placeName: String?,
        street: String?,
        city: String,
        region: String,
        postalCode: String,
        countryCode: String
    ) -> String {
        let place = placeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let streetTrimmed = street?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Prefer place-name first when both exist (e.g. "Old Trafford" above street).
        let line1: String
        let line2: String
        if !place.isEmpty, !streetTrimmed.isEmpty {
            line1 = place
            line2 = streetTrimmed
        } else if !streetTrimmed.isEmpty {
            line1 = streetTrimmed
            line2 = ""
        } else {
            line1 = place
            line2 = ""
        }
        let formatted = BusinessVenueAddressFormatter.formattedAddress(
            line1: line1,
            line2: line2,
            locality: city,
            region: region,
            postalCode: postalCode,
            countryCode: countryCode
        )
        if !formatted.isEmpty { return formatted }
        // Legacy rows without country: keep prior city/region concatenation.
        return localityLine(city: city, region: region, postalCode: postalCode, countryCode: "")
    }

    /// Suggested default country for new manual entry (never locked).
    static func suggestedDefaultCountryCode() -> String {
        if let region = Locale.current.region?.identifier {
            let code = BusinessLocationCountryPolicy.normalizedStoredCountryCode(region)
            if code.count == 2, BusinessLocationCountryPolicy.supportedCountryCodes.contains(code) {
                return code
            }
        }
        return ""
    }

    /// Soft validation — international (no US ZIP/state regex).
    static func manualEntryValidationError(
        placeName: String,
        address: String,
        city: String,
        countryCode: String,
        languageCode: String
    ) -> String? {
        let code = BusinessLocationCountryPolicy.normalizedStoredCountryCode(countryCode)
        // Require a real ISO 3166-1 alpha-2 (not empty / not legacy OTHER).
        if code.count != 2 || code == "OTHER" {
            return L10n.t("team_location_country_required", languageCode: languageCode)
        }
        let hasPlace = !placeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasStreet = !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasCity = !city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !hasPlace && !hasStreet && !hasCity {
            return L10n.t("team_location_incomplete", languageCode: languageCode)
        }
        return nil
    }

    nonisolated private static let europeStyleCountryCodes: Set<String> = [
        "AL", "AD", "AT", "BY", "BE", "BA", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR",
        "DE", "GR", "HU", "IS", "IE", "IT", "XK", "LV", "LI", "LT", "LU", "MT", "MD", "MC",
        "ME", "NL", "MK", "NO", "PL", "PT", "RO", "RU", "SM", "RS", "SK", "SI", "ES", "SE",
        "CH", "UA", "GB", "VA"
    ]

    /// Soft cap so the Choose Location picker stays scannable.
    static let recentDisplayLimit = 12

    /// Saved locations first (default pinned), then recent-only (exclude saved duplicates).
    static func split(locations: [FanTeamLocation]) -> (saved: [FanTeamLocation], recent: [FanTeamLocation]) {
        let saved = locations
            .filter(\.isSaved)
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault && !rhs.isDefault }
                let ln = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                if ln != .orderedSame { return ln == .orderedAscending }
                return lhs.updatedAt > rhs.updatedAt
            }
        let savedKeys = Set(saved.map(\.identityKey))
        let recent = locations
            .filter { !$0.isSaved && $0.lastUsedAt != nil && !savedKeys.contains($0.identityKey) }
            .sorted { lhs, rhs in
                let lUsed = lhs.lastUsedAt ?? .distantPast
                let rUsed = rhs.lastUsedAt ?? .distantPast
                if lUsed != rUsed { return lUsed > rUsed }
                if lhs.usageCount != rhs.usageCount { return lhs.usageCount > rhs.usageCount }
                return lhs.updatedAt > rhs.updatedAt
            }
        return (saved, Array(recent.prefix(recentDisplayLimit)))
    }

    /// True when a newly chosen place already exists under Saved (by id or identity key).
    static func isSelectionAlreadySaved(
        _ selection: FanTeamLocationSelection,
        amongSaved saved: [FanTeamLocation]
    ) -> Bool {
        if let id = selection.teamLocationId, saved.contains(where: { $0.id == id }) {
            return true
        }
        guard let key = identityKey(
            providerPlaceId: selection.providerPlaceId,
            latitude: selection.latitude,
            longitude: selection.longitude,
            address: selection.address,
            city: selection.city,
            state: selection.state,
            placeName: selection.placeName
        ) else {
            return false
        }
        return saved.contains(where: { $0.identityKey == key })
    }

    static func recentUsageCaption(
        lastUsedAt: Date?,
        usageCount: Int,
        now: Date = Date(),
        languageCode: String
    ) -> String {
        if usageCount > 1 {
            return String(
                format: L10n.t("team_location_used_times_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode.replacingOccurrences(of: "-", with: "_")),
                Int64(usageCount)
            )
        }
        guard let lastUsedAt else {
            return L10n.t("team_location_used_recently", languageCode: languageCode)
        }
        let calendar = Calendar.current
        if calendar.isDateInToday(lastUsedAt) || calendar.isDateInYesterday(lastUsedAt) {
            if calendar.isDateInYesterday(lastUsedAt) {
                return L10n.t("team_location_used_yesterday", languageCode: languageCode)
            }
            return L10n.t("team_location_used_recently", languageCode: languageCode)
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: lastUsedAt), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 7 {
            return L10n.t("team_location_used_last_week", languageCode: languageCode)
        }
        return L10n.t("team_location_used_recently", languageCode: languageCode)
    }

    static func accessibilityLabel(
        location: FanTeamLocation,
        languageCode: String
    ) -> String {
        var parts: [String] = []
        if location.isSaved {
            parts.append(L10n.t("team_location_a11y_saved", languageCode: languageCode))
        } else {
            parts.append(L10n.t("team_location_a11y_recent", languageCode: languageCode))
        }
        parts.append(location.title)
        if let place = location.subtitlePlace {
            parts.append(place)
        }
        let addr = location.addressLine
        if !addr.isEmpty, addr.caseInsensitiveCompare(location.title) != .orderedSame {
            parts.append(addr)
        }
        if location.isDefault {
            parts.append(L10n.t("team_location_a11y_default", languageCode: languageCode))
        }
        if !location.isSaved, location.lastUsedAt != nil {
            parts.append(
                recentUsageCaption(
                    lastUsedAt: location.lastUsedAt,
                    usageCount: location.usageCount,
                    languageCode: languageCode
                )
            )
        }
        return parts.joined(separator: ", ")
    }

    /// Client-side identity for optimistic dedupe (mirrors SQL preference order).
    static func identityKey(
        providerPlaceId: String?,
        latitude: Double?,
        longitude: Double?,
        address: String?,
        city: String?,
        state: String?,
        placeName: String?
    ) -> String? {
        let provider = providerPlaceId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !provider.isEmpty { return "provider:\(provider)" }

        let addr = normalize(address)
        let c = normalize(city)
        let s = normalize(state)
        let place = normalize(placeName)

        if let latitude, let longitude, latitude.isFinite, longitude.isFinite {
            let lat = String(format: "%.5f", (latitude * 100_000).rounded() / 100_000)
            let lon = String(format: "%.5f", (longitude * 100_000).rounded() / 100_000)
            if !addr.isEmpty || !c.isEmpty || !s.isEmpty {
                return "geoaddr:\(lat),\(lon)|\(addr)|\(c)|\(s)"
            }
            if !place.isEmpty {
                return "geoname:\(lat),\(lon)|\(place)"
            }
            return "geo:\(lat),\(lon)"
        }
        if !addr.isEmpty || !c.isEmpty || !s.isEmpty {
            return "addr:\(addr)|\(c)|\(s)|\(place)"
        }
        if !place.isEmpty { return "name:\(place)" }
        return nil
    }

    private static func normalize(_ raw: String?) -> String {
        (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
