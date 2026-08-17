import Foundation

/// Internal FanGeo chat pickup-game share payload (encoded in message body — no migration).
nonisolated struct PickupGameSharePayload: Codable, Equatable, Sendable {
    let v: Int
    let pickupGameId: UUID
    let title: String
    let sport: String
    let gameStartAt: String
    let endTime: String?
    let placeName: String?
    let city: String?
    let region: String?
    let address: String?
    let organizerDisplayName: String?
    let organizerAvatarThumbnailURL: String?
    let approvedJoinCount: Int?
    let playersNeeded: Int?
    let maxPlayers: Int?
    /// Display status token: `active`, `full`, `cancelled`, or other stored status.
    let status: String
    let sharedByName: String?

    enum CodingKeys: String, CodingKey {
        case v
        case pickupGameId = "pickup_game_id"
        case title
        case sport
        case gameStartAt = "game_start_at"
        case endTime = "end_time"
        case placeName = "place_name"
        case city
        case region
        case address
        case organizerDisplayName = "organizer_display_name"
        case organizerAvatarThumbnailURL = "organizer_avatar_thumbnail_url"
        case approvedJoinCount = "approved_join_count"
        case playersNeeded = "players_needed"
        case maxPlayers = "max_players"
        case status
        case sharedByName = "shared_by_name"
    }

    init(
        pickupGameId: UUID,
        title: String,
        sport: String,
        gameStartAt: String,
        endTime: String?,
        placeName: String?,
        city: String?,
        region: String?,
        address: String?,
        organizerDisplayName: String?,
        organizerAvatarThumbnailURL: String?,
        approvedJoinCount: Int?,
        playersNeeded: Int?,
        maxPlayers: Int?,
        status: String,
        sharedByName: String?
    ) {
        self.v = 1
        self.pickupGameId = pickupGameId
        self.title = title
        self.sport = sport
        self.gameStartAt = gameStartAt
        self.endTime = endTime
        self.placeName = placeName
        self.city = city
        self.region = region
        self.address = address
        self.organizerDisplayName = organizerDisplayName
        self.organizerAvatarThumbnailURL = organizerAvatarThumbnailURL
        self.approvedJoinCount = approvedJoinCount
        self.playersNeeded = playersNeeded
        self.maxPlayers = maxPlayers
        self.status = status
        self.sharedByName = sharedByName
    }
}

enum PickupGameShareMessage {
    nonisolated static let sentinel = "__FG_PICKUP_SHARE_V1__"

    /// Builds a share payload from a visible, shareable pickup game.
    static func payload(
        from game: PickupGameRow,
        organizerDisplayName: String?,
        organizerAvatarThumbnailURL: String?,
        sharedByDisplayName: String,
        languageCode: String
    ) -> PickupGameSharePayload? {
        guard game.isEligibleForInAppShare() else { return nil }

        let title = game.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let address = game.address?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let city = game.city?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let region = game.state?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let placeName = address ?? [city, region].compactMap { $0 }.joined(separator: ", ").nilIfEmpty

        let statusToken: String = {
            let raw = game.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if raw == "cancelled" || raw == "canceled" { return "cancelled" }
            if game.isPickupFullForDiscover { return "full" }
            return raw.isEmpty ? "active" : raw
        }()

        let organizer = organizerDisplayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let avatar = ImageDisplayURL.canonicalStorageURLString(organizerAvatarThumbnailURL)
            .nilIfEmpty

        _ = languageCode // reserved for future localized preview lines in encodeBody

        return PickupGameSharePayload(
            pickupGameId: game.id,
            title: title,
            sport: game.sport,
            gameStartAt: game.game_start_at,
            endTime: game.end_time,
            placeName: placeName,
            city: city,
            region: region,
            address: address,
            organizerDisplayName: organizer,
            organizerAvatarThumbnailURL: avatar,
            approvedJoinCount: game.approved_join_count,
            playersNeeded: game.players_needed,
            maxPlayers: game.max_players,
            status: statusToken,
            sharedByName: sharedByDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    static func encodeBody(payload: PickupGameSharePayload) -> String {
        let preview = previewLine(for: payload)
        guard let jsonData = try? JSONEncoder().encode(payload),
              let json = String(data: jsonData, encoding: .utf8) else {
            return preview
        }
        return "\(preview)\n\(sentinel)\(json)"
    }

    /// Pure sentinel + JSON decode — no MainActor state.
    nonisolated static func decode(from body: String) -> PickupGameSharePayload? {
        guard let range = body.range(of: sentinel) else { return nil }
        let jsonPart = body[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonPart.data(using: .utf8),
              let payload = try? JSONDecoder().decode(PickupGameSharePayload.self, from: data),
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
        return prefix.isEmpty ? "Shared a FanGeo pickup game" : prefix
    }

    static func previewLine(for payload: PickupGameSharePayload) -> String {
        let sharer = payload.sharedByName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sharerPrefix = (sharer?.isEmpty == false)
            ? "\(sharer!) shared a FanGeo pickup game: "
            : "Shared a FanGeo pickup game: "
        let sport = SportSubtypeCatalog.identityLine(
            sport: payload.sport,
            subtype: nil,
            languageCode: nil
        )
        return "\(sharerPrefix)\(payload.title) · \(sport)"
    }
}

extension PickupGameRow {
    /// Visible, non-draft games that a viewer who already has the row may share in-app.
    func isEligibleForInAppShare(now: Date = Date()) -> Bool {
        guard is_visible else { return false }
        let st = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if st == "removed" || st == "expired" || st == "draft" { return false }
        if let raw = remove_after_at,
           let removeAfter = PickupGameModels.parseSupabaseTimestamptz(raw),
           removeAfter <= now,
           st != "cancelled",
           st != "canceled" {
            // Past cleanup window and not an organizer-canceled card the viewer still holds.
            return false
        }
        return st == "active" || st == "cancelled" || st == "canceled"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
