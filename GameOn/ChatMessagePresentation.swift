import Foundation

/// Immutable presentation model for a chat message body.
/// Built on demand during row render (pre–Phase 1 cache behavior).
enum ChatMessagePresentation: Equatable, Sendable {
    case text(String)
    case profileShare(FanProfileSharePayload)
    case pickupShare(PickupGameSharePayload)
    case proShare(ProGameSharePayload)
    case venueShare(VenueSharePayload)
    case locationShare(ChatLocationSharePayload)
    case liveLocation(ChatLiveLocationSharePayload)
    case onMyWay(ChatOnMyWayPayload)
    case poll(PickupGamePollPayload)
    case unavailable(FanGeoStructuredChatKind)

    /// Pure structured-body decode: sentinel first, then one decoder.
    nonisolated static func build(body: String, messageType: String? = nil) -> ChatMessagePresentation {
        if GroupSystemEventFormatting.isSystemMessage(messageType: messageType) {
            return .text(body)
        }

        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .text(body)
        }

        guard let kind = FanGeoStructuredChatKind.recognized(in: trimmed) else {
            return .text(body)
        }

        switch kind {
        case .profileShare:
            if let payload = FanProfileShareMessage.decode(from: trimmed) {
                return .profileShare(payload)
            }
        case .pickupShare:
            if let payload = PickupGameShareMessage.decode(from: trimmed) {
                return .pickupShare(payload)
            }
        case .proShare:
            if let payload = ProGameShareMessage.decode(from: trimmed) {
                return .proShare(payload)
            }
        case .venueShare:
            if let payload = VenueShareMessage.decode(from: trimmed) {
                return .venueShare(payload)
            }
        case .locationShare:
            if let payload = ChatLocationShareMessage.decode(from: trimmed) {
                return .locationShare(payload)
            }
        case .liveLocation:
            if let payload = ChatLiveLocationShareMessage.decode(from: trimmed) {
                return .liveLocation(payload)
            }
        case .onMyWay:
            if let payload = ChatOnMyWayMessage.decode(from: trimmed) {
                return .onMyWay(payload)
            }
        case .poll:
            if let payload = PickupGamePollMessage.decode(from: trimmed) {
                return .poll(payload)
            }
        }

        return .unavailable(kind)
    }
}
