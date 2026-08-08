#if DEBUG
import Foundation

/// Encode/decode + privacy-safe preview checks for chat location / On My Way cards.
enum ChatLocationShareSelfTests {
    static func runAll() {
        let userId = UUID()
        let locationPayload = ChatLocationSharePayload(
            latitude: 40.7128,
            longitude: -74.0060,
            capturedAt: Date(),
            placeLabel: "New York",
            sharedByName: "Jonathan",
            sharedByUserId: userId,
            accuracyM: 12
        )
        let locationBody = ChatLocationShareMessage.encodeBody(payload: locationPayload)
        let decodedLocation = ChatLocationShareMessage.decode(from: locationBody)
        assert(decodedLocation != nil)
        assert(decodedLocation?.latitude == 40.7128)
        let locationPreview = ChatLocationShareMessage.inboxPreview(from: locationBody, languageCode: "en")
            ?? ""
        assert(locationPreview == "Shared a location.")
        assert(!locationPreview.contains("40.7128"))
        assert(!locationPreview.contains("-74.0060"))
        let locationPush = ChatLocationShareMessage.previewLine(for: locationPayload, languageCode: "en")
        assert(locationPush == "Jonathan shared a location.")
        assert(!locationPush.contains("40.7128"))

        let sessionId = UUID()
        let livePayload = ChatLiveLocationSharePayload(
            sessionId: sessionId,
            sharedByName: "Jonathan",
            sharedByUserId: userId,
            expiresAt: Date().addingTimeInterval(900),
            initialPlaceLabel: "Brooklyn"
        )
        let liveBody = ChatLiveLocationShareMessage.encodeBody(payload: livePayload)
        let decodedLive = ChatLiveLocationShareMessage.decode(from: liveBody)
        assert(decodedLive?.sessionId == sessionId)
        let livePreview = ChatLiveLocationShareMessage.inboxPreview(from: liveBody, languageCode: "en") ?? ""
        assert(livePreview == "Started sharing a live location.")
        assert(!livePreview.contains("40."))
        let livePush = ChatLiveLocationShareMessage.previewLine(for: livePayload, languageCode: "en")
        assert(livePush == "Jonathan started sharing a live location.")
        assert(!livePush.contains("Brooklyn"))

        let onMyWay = ChatOnMyWayPayload(
            v: 1,
            destinationName: "Jordan River",
            latitude: 40.75,
            longitude: -111.88,
            sharedByName: "Jonathan",
            sharedByUserId: userId,
            departedAt: ISO8601DateFormatter.chatLocation.string(from: Date()),
            estimatedArrivalAt: nil,
            etaMinutes: 15,
            distanceMeters: 3200,
            transportMode: "driving",
            etaSource: "manual",
            pickupGameId: nil,
            venueId: nil,
            liveSessionId: nil,
            status: "en_route",
            arrivedAt: nil
        )
        let omwBody = ChatOnMyWayMessage.encodeBody(payload: onMyWay)
        assert(ChatOnMyWayMessage.decode(from: omwBody)?.destinationName == "Jordan River")
        let omwPreview = ChatOnMyWayMessage.inboxPreview(from: omwBody, languageCode: "en") ?? ""
        assert(omwPreview == "Jonathan is on the way.")
        assert(!omwPreview.contains("Jordan River"))
        assert(!omwPreview.contains("40.75"))
        assert(!omwPreview.lowercased().contains("eta"))

        let arrived = ChatOnMyWayPayload(
            v: 1,
            destinationName: "Jordan River",
            latitude: 40.75,
            longitude: -111.88,
            sharedByName: "Jonathan",
            sharedByUserId: userId,
            departedAt: onMyWay.departedAt,
            estimatedArrivalAt: nil,
            etaMinutes: nil,
            distanceMeters: nil,
            transportMode: "driving",
            etaSource: "manual",
            pickupGameId: nil,
            venueId: nil,
            liveSessionId: nil,
            status: "arrived",
            arrivedAt: ISO8601DateFormatter.chatLocation.string(from: Date())
        )
        let arrivedPreview = ChatOnMyWayMessage.previewLine(for: arrived, languageCode: "en")
        assert(arrivedPreview == "Arrived.")
        assert(!arrivedPreview.contains("Jordan River"))
        assert(!arrivedPreview.contains("40.75"))

        // Corrupt structured body must not be treated as plaintext-safe by helpers.
        let corrupt = "__FG_LOCATION_SHARE_V1__{\"v\":99,\"latitude\":40.7,\"longitude\":-74.0}"
        assert(ChatLocationShareMessage.decode(from: corrupt) == nil)
        assert(FanGeoStructuredChatKind.recognized(in: corrupt) == .locationShare)
        assert(ChatLocationShareMessage.inboxPreview(from: corrupt, languageCode: "en") == "Shared a location.")

        _ = ChatLiveLocationDuration.minutes15.expiresAt
        _ = ChatLiveLocationDuration.hour1.expiresAt
    }
}
#endif
