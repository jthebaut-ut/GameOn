import CoreLocation
import Foundation

/// Internal FanGeo chat favorite-spot / venue share payload (encoded in message body — no migration).
nonisolated struct VenueSharePayload: Codable, Equatable, Sendable {
    let v: Int
    let venueId: UUID
    let name: String
    let coverPhotoURL: String?
    let coverPhotoThumbnailURL: String?
    let address: String?
    let city: String?
    let region: String?
    let country: String?
    /// Public venue kind label (e.g. place type / community type), not an internal enum.
    let venueType: String?
    let primarySport: String?
    let hostedEventTitles: [String]?
    let latitude: Double?
    let longitude: Double?
    let sharedByName: String?

    enum CodingKeys: String, CodingKey {
        case v
        case venueId = "venue_id"
        case name
        case coverPhotoURL = "cover_photo_url"
        case coverPhotoThumbnailURL = "cover_photo_thumbnail_url"
        case address
        case city
        case region
        case country
        case venueType = "venue_type"
        case primarySport = "primary_sport"
        case hostedEventTitles = "hosted_event_titles"
        case latitude
        case longitude
        case sharedByName = "shared_by_name"
    }

    init(
        venueId: UUID,
        name: String,
        coverPhotoURL: String?,
        coverPhotoThumbnailURL: String?,
        address: String?,
        city: String?,
        region: String?,
        country: String?,
        venueType: String?,
        primarySport: String?,
        hostedEventTitles: [String]?,
        latitude: Double?,
        longitude: Double?,
        sharedByName: String?
    ) {
        self.v = 1
        self.venueId = venueId
        self.name = name
        self.coverPhotoURL = coverPhotoURL
        self.coverPhotoThumbnailURL = coverPhotoThumbnailURL
        self.address = address
        self.city = city
        self.region = region
        self.country = country
        self.venueType = venueType
        self.primarySport = primarySport
        self.hostedEventTitles = hostedEventTitles
        self.latitude = latitude
        self.longitude = longitude
        self.sharedByName = sharedByName
    }
}

enum VenueShareMessage {
    nonisolated static let sentinel = "__FG_VENUE_SHARE_V1__"

    static func payload(
        from bar: BarVenue,
        sharedByDisplayName: String
    ) -> VenueSharePayload? {
        let name = bar.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        let address = bar.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let addressValue: String? = {
            guard !address.isEmpty, address != VenueAddressPlaceholder.sentinel else { return nil }
            return address
        }()

        let venueType = [
            bar.placeType,
            bar.communityType
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        .first

        let sport = bar.primarySport.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let events = bar.games
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(3)
            .map { String($0) }

        let coordsUsable = CLLocationCoordinate2DIsValid(bar.coordinate)
            && !(abs(bar.coordinate.latitude) < 0.000_01 && abs(bar.coordinate.longitude) < 0.000_01)

        return VenueSharePayload(
            venueId: bar.id,
            name: name,
            coverPhotoURL: ImageDisplayURL.canonicalStorageURLString(bar.coverPhotoURL).nilIfEmpty,
            coverPhotoThumbnailURL: ImageDisplayURL.canonicalStorageURLString(bar.coverPhotoThumbnailURL).nilIfEmpty,
            address: addressValue,
            city: nil,
            region: nil,
            country: nil,
            venueType: venueType,
            primarySport: sport,
            hostedEventTitles: events.isEmpty ? nil : Array(events),
            latitude: coordsUsable ? bar.coordinate.latitude : nil,
            longitude: coordsUsable ? bar.coordinate.longitude : nil,
            sharedByName: sharedByDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    static func encodeBody(payload: VenueSharePayload) -> String {
        let preview = previewLine(for: payload)
        guard let jsonData = try? JSONEncoder().encode(payload),
              let json = String(data: jsonData, encoding: .utf8) else {
            return preview
        }
        return "\(preview)\n\(sentinel)\(json)"
    }

    /// Pure sentinel + JSON decode — no MainActor state.
    nonisolated static func decode(from body: String) -> VenueSharePayload? {
        guard let range = body.range(of: sentinel) else { return nil }
        let jsonPart = body[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonPart.data(using: .utf8),
              let payload = try? JSONDecoder().decode(VenueSharePayload.self, from: data),
              payload.v == 1 else {
            return nil
        }
        return payload
    }

    static func inboxPreview(from body: String) -> String? {
        if let payload = decode(from: body) {
            return previewLine(for: payload)
        }
        guard let sentinelRange = body.range(of: sentinel) else { return nil }
        let prefix = body[..<sentinelRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? "Shared a FanGeo favorite spot" : prefix
    }

    static func previewLine(for payload: VenueSharePayload) -> String {
        let sharer = payload.sharedByName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sharerPrefix = (sharer?.isEmpty == false)
            ? "\(sharer!) shared a FanGeo favorite spot: "
            : "Shared a FanGeo favorite spot: "
        if let address = payload.address?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty {
            return "\(sharerPrefix)\(payload.name) · \(address)"
        }
        return "\(sharerPrefix)\(payload.name)"
    }

    static func locationLine(for payload: VenueSharePayload) -> String? {
        let parts = [payload.city, payload.region, payload.country]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: ", ") }
        let address = payload.address?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (address?.isEmpty == false) ? address : nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
