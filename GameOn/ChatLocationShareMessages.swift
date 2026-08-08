import CoreLocation
import Foundation

// MARK: - One-time location share

nonisolated struct ChatLocationSharePayload: Codable, Equatable, Sendable {
    let v: Int
    let latitude: Double
    let longitude: Double
    let capturedAt: String
    let placeLabel: String?
    let sharedByName: String?
    let sharedByUserId: UUID?
    let accuracyM: Double?

    enum CodingKeys: String, CodingKey {
        case v
        case latitude
        case longitude
        case capturedAt = "captured_at"
        case placeLabel = "place_label"
        case sharedByName = "shared_by_name"
        case sharedByUserId = "shared_by_user_id"
        case accuracyM = "accuracy_m"
    }

    init(
        latitude: Double,
        longitude: Double,
        capturedAt: Date,
        placeLabel: String?,
        sharedByName: String?,
        sharedByUserId: UUID?,
        accuracyM: Double?
    ) {
        self.v = 1
        self.latitude = latitude
        self.longitude = longitude
        self.capturedAt = ISO8601DateFormatter.chatLocation.string(from: capturedAt)
        self.placeLabel = placeLabel?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.sharedByName = sharedByName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.sharedByUserId = sharedByUserId
        self.accuracyM = accuracyM
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

enum ChatLocationShareMessage {
    nonisolated static let sentinel = "__FG_LOCATION_SHARE_V1__"

    static func encodeBody(payload: ChatLocationSharePayload) -> String {
        let preview = previewLine(for: payload)
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return preview
        }
        return "\(preview)\n\(sentinel)\(json)"
    }

    /// Pure sentinel + JSON decode + coordinate validation — no MainActor state.
    nonisolated static func decode(from body: String) -> ChatLocationSharePayload? {
        guard let range = body.range(of: sentinel) else { return nil }
        let jsonPart = body[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonPart.data(using: .utf8),
              let payload = try? JSONDecoder().decode(ChatLocationSharePayload.self, from: data),
              payload.v == 1,
              FanGeoDirectionsActions.hasUsableCoordinate(latitude: payload.latitude, longitude: payload.longitude)
        else {
            return nil
        }
        return payload
    }

    static func inboxPreview(from body: String, languageCode: String? = nil) -> String? {
        guard decode(from: body) != nil || body.contains(sentinel) else { return nil }
        return L10n.t("chat_location_inbox_shared_location", languageCode: languageCode)
    }

    static func previewLine(for payload: ChatLocationSharePayload, languageCode: String? = nil) -> String {
        if let name = payload.sharedByName, !name.isEmpty {
            return String(
                format: L10n.t("chat_location_shared_a_location_format", languageCode: languageCode),
                locale: Locale(identifier: L10n.normalizedLanguageCode(languageCode)),
                name
            )
        }
        return L10n.t("chat_location_inbox_shared_location", languageCode: languageCode)
    }
}

// MARK: - Live location share (stable card → session table)

enum ChatLiveLocationDuration: String, CaseIterable, Identifiable, Sendable {
    case minutes15
    case hour1

    var id: String { rawValue }

    /// Always non-nil — product only supports timed shares (15m / 1h).
    var expiresAt: Date {
        switch self {
        case .minutes15: return Date().addingTimeInterval(15 * 60)
        case .hour1: return Date().addingTimeInterval(60 * 60)
        }
    }

    func title(languageCode: String) -> String {
        switch self {
        case .minutes15:
            return L10n.t("chat_location_duration_15_min", languageCode: languageCode)
        case .hour1:
            return L10n.t("chat_location_duration_1_hour", languageCode: languageCode)
        }
    }
}

nonisolated struct ChatLiveLocationSharePayload: Codable, Equatable, Sendable {
    let v: Int
    let sessionId: UUID
    let sharedByName: String?
    let sharedByUserId: UUID?
    let expiresAt: String?
    let initialPlaceLabel: String?

    enum CodingKeys: String, CodingKey {
        case v
        case sessionId = "session_id"
        case sharedByName = "shared_by_name"
        case sharedByUserId = "shared_by_user_id"
        case expiresAt = "expires_at"
        case initialPlaceLabel = "initial_place_label"
    }

    init(
        sessionId: UUID,
        sharedByName: String?,
        sharedByUserId: UUID?,
        expiresAt: Date?,
        initialPlaceLabel: String?
    ) {
        self.v = 1
        self.sessionId = sessionId
        self.sharedByName = sharedByName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.sharedByUserId = sharedByUserId
        self.expiresAt = expiresAt.map { ISO8601DateFormatter.chatLocation.string(from: $0) }
        self.initialPlaceLabel = initialPlaceLabel?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

enum ChatLiveLocationShareMessage {
    nonisolated static let sentinel = "__FG_LIVE_LOCATION_V1__"

    static func encodeBody(payload: ChatLiveLocationSharePayload) -> String {
        let preview = previewLine(for: payload)
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return preview
        }
        return "\(preview)\n\(sentinel)\(json)"
    }

    /// Pure sentinel + JSON decode — no MainActor state.
    nonisolated static func decode(from body: String) -> ChatLiveLocationSharePayload? {
        guard let range = body.range(of: sentinel) else { return nil }
        let jsonPart = body[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonPart.data(using: .utf8),
              let payload = try? JSONDecoder().decode(ChatLiveLocationSharePayload.self, from: data),
              payload.v == 1
        else {
            return nil
        }
        return payload
    }

    static func inboxPreview(from body: String, languageCode: String? = nil) -> String? {
        guard decode(from: body) != nil || body.contains(sentinel) else { return nil }
        return L10n.t("chat_location_inbox_shared_live_location", languageCode: languageCode)
    }

    static func previewLine(for payload: ChatLiveLocationSharePayload, languageCode: String? = nil) -> String {
        if let name = payload.sharedByName, !name.isEmpty {
            return String(
                format: L10n.t("chat_location_shared_live_format", languageCode: languageCode),
                locale: Locale(identifier: L10n.normalizedLanguageCode(languageCode)),
                name
            )
        }
        return L10n.t("chat_location_inbox_shared_live_location", languageCode: languageCode)
    }
}

// MARK: - On My Way

nonisolated struct ChatOnMyWayPayload: Codable, Equatable, Sendable {
    let v: Int
    let destinationName: String
    let latitude: Double
    let longitude: Double
    let sharedByName: String?
    let sharedByUserId: UUID?
    let departedAt: String?
    let estimatedArrivalAt: String?
    let etaMinutes: Int?
    let distanceMeters: Double?
    let transportMode: String?
    let etaSource: String?
    let pickupGameId: UUID?
    let venueId: UUID?
    let liveSessionId: UUID?
    let status: String
    let arrivedAt: String?

    enum CodingKeys: String, CodingKey {
        case v
        case destinationName = "destination_name"
        case latitude
        case longitude
        case sharedByName = "shared_by_name"
        case sharedByUserId = "shared_by_user_id"
        case departedAt = "departed_at"
        case estimatedArrivalAt = "estimated_arrival_at"
        case etaMinutes = "eta_minutes"
        case distanceMeters = "distance_meters"
        case transportMode = "transport_mode"
        case etaSource = "eta_source"
        case pickupGameId = "pickup_game_id"
        case venueId = "venue_id"
        case liveSessionId = "live_session_id"
        case status
        case arrivedAt = "arrived_at"
    }

    var isArrived: Bool {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "arrived"
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

enum ChatOnMyWayMessage {
    nonisolated static let sentinel = "__FG_ON_MY_WAY_V1__"

    static func encodeBody(payload: ChatOnMyWayPayload) -> String {
        let preview = previewLine(for: payload)
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return preview
        }
        return "\(preview)\n\(sentinel)\(json)"
    }

    /// Pure sentinel + JSON decode + coordinate validation — no MainActor state.
    nonisolated static func decode(from body: String) -> ChatOnMyWayPayload? {
        guard let range = body.range(of: sentinel) else { return nil }
        let jsonPart = body[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonPart.data(using: .utf8),
              let payload = try? JSONDecoder().decode(ChatOnMyWayPayload.self, from: data),
              payload.v == 1,
              FanGeoDirectionsActions.hasUsableCoordinate(latitude: payload.latitude, longitude: payload.longitude)
        else {
            return nil
        }
        return payload
    }

    static func inboxPreview(from body: String, languageCode: String? = nil) -> String? {
        guard let payload = decode(from: body) else {
            return body.contains(sentinel)
                ? L10n.t("chat_on_my_way_inbox", languageCode: languageCode)
                : nil
        }
        return previewLine(for: payload, languageCode: languageCode)
    }

    static func previewLine(for payload: ChatOnMyWayPayload, languageCode: String? = nil) -> String {
        // Privacy: never include destination, address, coords, or ETA in inbox/push previews.
        if payload.isArrived {
            return L10n.t("chat_on_my_way_inbox_arrived_generic", languageCode: languageCode)
        }
        let name = payload.sharedByName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty {
            return L10n.t("chat_on_my_way_inbox_generic", languageCode: languageCode)
        }
        return String(
            format: L10n.t("chat_on_my_way_inbox_generic_format", languageCode: languageCode),
            locale: Locale(identifier: L10n.normalizedLanguageCode(languageCode)),
            name
        )
    }
}

// MARK: - Helpers

private extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension ISO8601DateFormatter {
    nonisolated static let chatLocation: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
