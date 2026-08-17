import CoreLocation
import Foundation

/// How much of the Team Location is shown on Discover.
enum FanTeamDiscoveryLocationPrecision: String, Codable, Equatable, Sendable {
    case specific
    case generalArea = "general_area"

    static func parse(_ raw: String?) -> FanTeamDiscoveryLocationPrecision {
        switch (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "general_area", "general": return .generalArea
        default: return .specific
        }
    }
}

/// Owner-edited discovery settings (`get_my_fan_team_discovery`).
struct FanTeamDiscoverySettings: Equatable, Sendable {
    var isDiscoverable: Bool
    var lookingForPlayers: Bool
    var sportSubtype: String?
    var precision: FanTeamDiscoveryLocationPrecision
    var placeName: String?
    var address: String?
    var city: String?
    var region: String?
    var postalCode: String?
    var countryCode: String?
    var latitude: Double?
    var longitude: Double?

    static let hidden = FanTeamDiscoverySettings(
        isDiscoverable: false,
        lookingForPlayers: false,
        sportSubtype: nil,
        precision: .specific,
        placeName: nil,
        address: nil,
        city: nil,
        region: nil,
        postalCode: nil,
        countryCode: nil,
        latitude: nil,
        longitude: nil
    )

    var hasValidDiscoveryCoordinate: Bool {
        FanTeamDiscoveryLocationPolicy.hasValidCoordinate(latitude: latitude, longitude: longitude)
    }

    var hasValidPublicLocation: Bool {
        FanTeamDiscoveryLocationPolicy.isValid(
            latitude: latitude,
            longitude: longitude,
            countryCode: countryCode,
            city: city,
            placeName: placeName
        )
    }

    /// `p_clear_location` for `update_fan_team_discovery`. Discover OFF with no
    /// remaining coordinate is the only client signal to erase a saved location.
    /// An unloaded/failed fetch must not be sent as this flag.
    var shouldClearStoredDiscoveryLocation: Bool {
        !isDiscoverable && !hasValidDiscoveryCoordinate
    }

    var selection: FanTeamLocationSelection? {
        guard hasValidDiscoveryCoordinate,
              let latitude, let longitude else { return nil }
        return FanTeamLocationSelection(
            placeName: placeName,
            address: address ?? "",
            city: city ?? "",
            state: region ?? "",
            zipCode: postalCode ?? "",
            countryCode: countryCode ?? "",
            latitude: latitude,
            longitude: longitude
        )
    }

    mutating func apply(selection: FanTeamLocationSelection) {
        placeName = selection.placeName
        address = selection.address
        city = selection.city
        region = selection.state
        postalCode = selection.zipCode
        countryCode = BusinessLocationCountryPolicy.normalizedStoredCountryCode(selection.countryCode)
        latitude = selection.latitude
        longitude = selection.longitude
    }

    mutating func clearLocation() {
        placeName = nil
        address = nil
        city = nil
        region = nil
        postalCode = nil
        countryCode = nil
        latitude = nil
        longitude = nil
    }

    func displayLocationSummary(languageCode _: String) -> String {
        guard hasValidDiscoveryCoordinate else { return "" }
        if precision == .generalArea {
            let locality = FanTeamLocationPresentation.localityLine(
                city: city ?? "",
                region: region ?? "",
                postalCode: "",
                countryCode: countryCode ?? ""
            )
            let country = BusinessLocationCountryPolicy.countryName(for: countryCode ?? "")
            return [locality, country].filter { !$0.isEmpty }.joined(separator: ", ")
        }
        return FanTeamLocationPresentation.formattedAddress(
            placeName: placeName,
            street: address ?? "",
            city: city ?? "",
            region: region ?? "",
            postalCode: postalCode ?? "",
            countryCode: countryCode ?? ""
        )
    }
}

enum FanTeamDiscoveryLocationPolicy {
    static func hasValidCoordinate(latitude: Double?, longitude: Double?) -> Bool {
        guard let latitude, let longitude,
              latitude.isFinite, longitude.isFinite,
              abs(latitude) <= 90, abs(longitude) <= 180,
              !(latitude == 0 && longitude == 0) else { return false }
        return true
    }

    static func isValid(
        latitude: Double?,
        longitude: Double?,
        countryCode: String?,
        city: String?,
        placeName: String?
    ) -> Bool {
        guard hasValidCoordinate(latitude: latitude, longitude: longitude) else { return false }
        let code = BusinessLocationCountryPolicy.normalizedStoredCountryCode(countryCode ?? "")
        guard code.count == 2 else { return false }
        let cityTrim = city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let placeTrim = placeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !cityTrim.isEmpty || !placeTrim.isEmpty
    }

    static func canSave(settings: FanTeamDiscoverySettings) -> Bool {
        if settings.isDiscoverable {
            return settings.hasValidPublicLocation
        }
        return true
    }
}

/// Edit Team → Discovery presentation only. Does not change stored coordinates,
/// RPC fields, or public Discover map-row formatting.
enum FanTeamDiscoveryEditorPresentation {
    /// Visual radius for General Area mini-map / privacy treatment. Presentation only.
    static let generalAreaRadiusMeters: CLLocationDistance = 1400

    static let localizationKeys: [String] = [
        "team_discovery_section_title",
        "team_discovery_show_on_discover",
        "team_discovery_show_on_discover_supporting",
        "team_discovery_looking_for_players",
        "team_discovery_looking_for_players_supporting",
        "team_discovery_looking_for_players_private_hint",
        "team_discovery_location_title",
        "team_discovery_location_supporting",
        "team_discovery_change",
        "team_discovery_choose_location",
        "team_discovery_specific_location",
        "team_discovery_general_area",
        "team_discovery_specific_explainer",
        "team_discovery_general_explainer",
        "team_discovery_location_privacy",
        "team_discovery_location_privacy_home",
        "team_discovery_what_others_will_see",
        "team_discovery_map_preview_specific_a11y",
        "team_discovery_map_preview_general_a11y",
        "team_discovery_editors_only",
        "team_discovery_location_required",
        "team_discovery_location_required_supporting"
    ]

    enum LocationChrome: Equatable {
        /// Discover OFF, no coordinate — compact add-location row, no map.
        case compactSetup
        /// Discover OFF, location kept for later — compact summary, no dominating map.
        case compactConfigured
        /// Discover ON, location missing — Choose Team Location CTA, no empty map.
        case prominentMissing
        /// Discover ON, valid coordinate — mini-map + precision + public preview.
        case prominentConfigured
    }

    static func locationChrome(for settings: FanTeamDiscoverySettings) -> LocationChrome {
        if settings.isDiscoverable {
            return settings.hasValidDiscoveryCoordinate ? .prominentConfigured : .prominentMissing
        }
        return settings.hasValidDiscoveryCoordinate ? .compactConfigured : .compactSetup
    }

    static func showsMiniMap(settings: FanTeamDiscoverySettings) -> Bool {
        locationChrome(for: settings) == .prominentConfigured
    }

    static func showsEmptyMap(settings _: FanTeamDiscoverySettings) -> Bool {
        false
    }

    static func showsPublicPreview(settings: FanTeamDiscoverySettings) -> Bool {
        settings.isDiscoverable && settings.hasValidPublicLocation
    }

    static func showsChooseLocationCTA(settings: FanTeamDiscoverySettings) -> Bool {
        locationChrome(for: settings) == .prominentMissing
    }

    /// Recruiting is stored independently. It is only advertised publicly when Discover is ON.
    static func publiclyAdvertisesRecruiting(settings: FanTeamDiscoverySettings) -> Bool {
        settings.isDiscoverable && settings.lookingForPlayers
    }

    static func mapIdentity(for settings: FanTeamDiscoverySettings) -> String {
        let lat = settings.latitude.map { String(format: "%.6f", $0) } ?? "none"
        let lon = settings.longitude.map { String(format: "%.6f", $0) } ?? "none"
        return "\(lat),\(lon),\(settings.precision.rawValue)"
    }

    static func mapCamera(for settings: FanTeamDiscoverySettings) -> (latitude: Double, longitude: Double, delta: Double)? {
        guard settings.hasValidDiscoveryCoordinate,
              let latitude = settings.latitude,
              let longitude = settings.longitude else { return nil }
        let delta = settings.precision == .generalArea ? 0.045 : 0.012
        return (latitude, longitude, delta)
    }

    static func publicPreviewRow(
        settings: FanTeamDiscoverySettings,
        teamId: UUID,
        name: String,
        sport: String,
        logoURL: String?,
        logoThumbnailURL: String?,
        colorHex: String?,
        memberCount: Int
    ) -> DiscoverableFanTeamMapRow? {
        guard showsPublicPreview(settings: settings),
              let latitude = settings.latitude,
              let longitude = settings.longitude else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        return DiscoverableFanTeamMapRow(
            id: teamId,
            name: trimmedName,
            sport: sport.trimmingCharacters(in: .whitespacesAndNewlines),
            sportSubtype: settings.sportSubtype,
            logoURL: logoURL,
            logoThumbnailURL: logoThumbnailURL,
            colorHex: colorHex,
            lookingForPlayers: publiclyAdvertisesRecruiting(settings: settings),
            memberCount: max(0, memberCount),
            precision: settings.precision,
            placeName: settings.placeName,
            city: settings.city,
            region: settings.region,
            postalCode: settings.postalCode,
            countryCode: settings.countryCode,
            latitude: latitude,
            longitude: longitude
        )
    }

    /// General Area public copy must not leak street, place name, or postal code.
    static func publicPreviewExposesStreetLevelDetail(
        row: DiscoverableFanTeamMapRow,
        street: String?,
        placeName: String?,
        postalCode: String?
    ) -> Bool {
        guard row.precision == .generalArea else { return false }
        let haystack = row.localityDisplayLine().localizedLowercase
        func leaks(_ raw: String?) -> Bool {
            let token = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard token.count >= 3 else { return false }
            return haystack.contains(token.localizedLowercase)
        }
        return leaks(street) || leaks(placeName) || leaks(postalCode)
    }
}

/// Public-safe Discover map row (`list_discoverable_fan_teams_in_bounds`).
struct DiscoverableFanTeamMapRow: Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let name: String
    let sport: String
    let sportSubtype: String?
    let logoURL: String?
    let logoThumbnailURL: String?
    let colorHex: String?
    let lookingForPlayers: Bool
    let memberCount: Int
    let precision: FanTeamDiscoveryLocationPrecision
    let placeName: String?
    let city: String?
    let region: String?
    let postalCode: String?
    let countryCode: String?
    let latitude: Double
    let longitude: Double
    /// Display-only artwork version. Changes when Team logo bytes/URL change; never a new Team id.
    var displayRefreshToken: UUID? = nil

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func applyingIdentityChange(_ change: FanTeamIdentityChange) -> DiscoverableFanTeamMapRow {
        FanTeamArtworkPropagation.applying(change, to: self)
    }

    var hasCustomLogo: Bool {
        let thumb = ImageDisplayURL.canonicalStorageURLString(logoThumbnailURL)
        let full = ImageDisplayURL.canonicalStorageURLString(logoURL)
        return !thumb.isEmpty || !full.isEmpty
    }

    func localityDisplayLine() -> String {
        if precision == .specific {
            let place = placeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !place.isEmpty { return place }
        }
        let locality = FanTeamLocationPresentation.localityLine(
            city: city ?? "",
            region: region ?? "",
            postalCode: precision == .specific ? (postalCode ?? "") : "",
            countryCode: countryCode ?? ""
        )
        let country = BusinessLocationCountryPolicy.countryName(for: countryCode ?? "")
        return [locality, country].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    func sportIdentityLine(languageCode: String) -> String {
        SportSubtypeCatalog.identityLine(
            sport: sport,
            subtype: sportSubtype,
            languageCode: languageCode
        )
    }

    func mapAccessibilityLabel(languageCode: String) -> String {
        var parts: [String] = [name]
        let sportLine = sportIdentityLine(languageCode: languageCode)
        if !sportLine.isEmpty {
            parts.append(
                String(
                    format: L10n.t("discover_team_pin_sport_team_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    sportLine
                )
            )
        }
        let locality = localityDisplayLine()
        if !locality.isEmpty { parts.append(locality) }
        if memberCount == 1 {
            parts.append(L10n.t("discover_team_members_one", languageCode: languageCode))
        } else if memberCount > 0 {
            parts.append(
                String(
                    format: L10n.t("discover_team_members_other_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    Int64(memberCount)
                )
            )
        }
        if lookingForPlayers {
            parts.append(L10n.t("team_discovery_looking_for_players", languageCode: languageCode))
        }
        return parts.joined(separator: ". ")
    }
}

nonisolated struct DiscoverableFanTeamCluster: Identifiable {
    let id: String
    let rows: [DiscoverableFanTeamMapRow]
    let coordinate: CLLocationCoordinate2D

    var count: Int { rows.count }
}

struct FanTeamDiscoveryRPCRow: Decodable, Sendable {
    let team_id: UUID
    let name: String?
    let sport: String?
    let sport_subtype: String?
    let logo_url: String?
    let logo_thumbnail_url: String?
    let color_hex: String?
    let looking_for_players: Bool?
    let member_count: Int?
    let location_precision: String?
    let place_name: String?
    let city: String?
    let region: String?
    let postal_code: String?
    let country_code: String?
    let latitude: Double?
    let longitude: Double?

    func asMapRow() -> DiscoverableFanTeamMapRow? {
        guard let latitude, let longitude,
              FanTeamDiscoveryLocationPolicy.hasValidCoordinate(latitude: latitude, longitude: longitude)
        else { return nil }
        let name = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return DiscoverableFanTeamMapRow(
            id: team_id,
            name: name,
            sport: (sport ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            sportSubtype: sport_subtype?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            logoURL: ImageDisplayURL.canonicalStorageURLString(logo_url).nilIfEmpty,
            logoThumbnailURL: ImageDisplayURL.canonicalStorageURLString(logo_thumbnail_url).nilIfEmpty,
            colorHex: FanTeamColorPalette.normalized(color_hex),
            lookingForPlayers: looking_for_players ?? false,
            memberCount: max(0, member_count ?? 0),
            precision: FanTeamDiscoveryLocationPrecision.parse(location_precision),
            placeName: place_name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            city: city?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            region: region?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            postalCode: postal_code?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            countryCode: BusinessLocationCountryPolicy.normalizedStoredCountryCode(country_code ?? "")
                .nilIfEmpty,
            latitude: latitude,
            longitude: longitude
        )
    }
}

struct FanTeamMyDiscoveryRPCRow: Decodable, Sendable {
    let team_id: UUID
    let is_discoverable: Bool?
    let looking_for_players: Bool?
    let sport_subtype: String?
    let location_precision: String?
    let place_name: String?
    let address: String?
    let city: String?
    let region: String?
    let postal_code: String?
    let country_code: String?
    let latitude: Double?
    let longitude: Double?

    func asSettings() -> FanTeamDiscoverySettings {
        FanTeamDiscoverySettings(
            isDiscoverable: is_discoverable ?? false,
            lookingForPlayers: looking_for_players ?? false,
            sportSubtype: sport_subtype?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            precision: FanTeamDiscoveryLocationPrecision.parse(location_precision),
            placeName: place_name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            address: address?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            city: city?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            region: region?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            postalCode: postal_code?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            countryCode: BusinessLocationCountryPolicy.normalizedStoredCountryCode(country_code ?? "")
                .nilIfEmpty,
            latitude: latitude,
            longitude: longitude
        )
    }
}

enum FanTeamDiscoveryCopy {
    static func statusLine(
        placeCount: Int,
        teamCount: Int,
        sport: String?,
        languageCode: String
    ) -> String {
        let locale = Locale(identifier: L10n.normalizedLanguageCode(languageCode))
        if placeCount <= 0 && teamCount <= 0 {
            return L10n.t("discover_status_no_places_or_teams", languageCode: languageCode)
        }
        if placeCount > 0 && teamCount > 0 {
            return String(
                format: L10n.t("discover_status_places_and_teams_format", languageCode: languageCode),
                locale: locale,
                Int64(placeCount),
                Int64(teamCount)
            )
        }
        if teamCount > 0 {
            return teamCount == 1
                ? L10n.t("discover_status_team_one", languageCode: languageCode)
                : String(format: L10n.t("discover_status_team_other_format", languageCode: languageCode), locale: locale, Int64(teamCount))
        }
        if let sport {
            return placeCount == 1
                ? String(format: L10n.t("discover_status_sport_place_one_format", languageCode: languageCode), locale: locale, sport)
                : String(format: L10n.t("discover_status_sport_place_other_format", languageCode: languageCode), locale: locale, Int64(placeCount), sport)
        }
        return placeCount == 1
            ? L10n.t("discover_status_pickup_place_one", languageCode: languageCode)
            : String(format: L10n.t("discover_status_pickup_place_other_format", languageCode: languageCode), locale: locale, Int64(placeCount))
    }

    static func emptyTitle(
        placeCount: Int,
        teamCount: Int,
        languageCode: String
    ) -> String? {
        if placeCount == 0 && teamCount == 0 {
            return L10n.t("discover_empty_places_or_teams_nearby", languageCode: languageCode)
        }
        return nil
    }

    static func emptySupporting(languageCode: String) -> String {
        L10n.t("discover_empty_recovery_places_or_teams", languageCode: languageCode)
    }
}

/// Canonical Discover → View Team routing.
///
/// Discoverability, recruiting, public location, and public event visibility
/// never grant private Team workspace access. Only `list_my_fan_teams` rows
/// with ``FanTeamSummary/hasTeamAccountAccess`` open `FanTeamDetailSheet`.
enum FanTeamDiscoverWorkspaceRouting {
    enum Destination: Equatable {
        case privateWorkspace
        case publicProfile
    }

    /// Public-safe fields returned by `list_discoverable_fan_teams_in_bounds`
    /// / `get_public_fan_team_summary`. Anything else must not be fetched for
    /// an outsider public profile.
    static let publicSafeSummaryFields: Set<String> = [
        "team_id",
        "name",
        "sport",
        "sport_subtype",
        "logo_url",
        "logo_thumbnail_url",
        "color_hex",
        "looking_for_players",
        "member_count",
        "location_precision",
        "place_name",
        "city",
        "region",
        "postal_code",
        "country_code",
        "latitude",
        "longitude",
    ]

    static func destination(
        teamId: UUID,
        isAuthenticated: Bool,
        myTeams: [FanTeamSummary]
    ) -> Destination {
        guard isAuthenticated else { return .publicProfile }
        guard let summary = myTeams.first(where: { $0.id == teamId }) else {
            return .publicProfile
        }
        return summary.hasTeamAccountAccess ? .privateWorkspace : .publicProfile
    }

    static func workspaceSummary(
        teamId: UUID,
        isAuthenticated: Bool,
        myTeams: [FanTeamSummary]
    ) -> FanTeamSummary? {
        guard destination(teamId: teamId, isAuthenticated: isAuthenticated, myTeams: myTeams) == .privateWorkspace else {
            return nil
        }
        return myTeams.first(where: { $0.id == teamId })
    }

    /// Public profile never composes Team Detail tabs.
    static var publicProfilePrivateTabs: [FanTeamDetailTab] { [] }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
