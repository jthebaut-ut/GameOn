import SwiftUI

/// Recognized FanGeo structured chat sentinels. Decode failures must never fall through to plaintext.
nonisolated enum FanGeoStructuredChatKind: String, Sendable {
    case locationShare
    case liveLocation
    case onMyWay
    case poll
    case profileShare
    case pickupShare
    case proShare
    case venueShare

    /// Immutable sentinel strings only — safe off the MainActor for classification.
    var sentinel: String {
        switch self {
        case .locationShare: return ChatLocationShareMessage.sentinel
        case .liveLocation: return ChatLiveLocationShareMessage.sentinel
        case .onMyWay: return ChatOnMyWayMessage.sentinel
        case .poll: return PickupGamePollMessage.sentinel
        case .profileShare: return FanProfileShareMessage.sentinel
        case .pickupShare: return PickupGameShareMessage.sentinel
        case .proShare: return ProGameShareMessage.sentinel
        case .venueShare: return VenueShareMessage.sentinel
        }
    }

    /// Fixed recognition order (immutable). Safe off the MainActor.
    static let allCasesOrdered: [FanGeoStructuredChatKind] = [
        .locationShare, .liveLocation, .onMyWay, .poll,
        .profileShare, .pickupShare, .proShare, .venueShare
    ]

    /// Pure sentinel scan — no UI, services, or mutable state.
    static func recognized(in body: String) -> FanGeoStructuredChatKind? {
        for kind in allCasesOrdered where body.contains(kind.sentinel) {
            return kind
        }
        return nil
    }

    @MainActor
    func unavailableTitle(languageCode: String?) -> String {
        switch self {
        case .locationShare, .liveLocation:
            return L10n.t("chat_structured_location_unavailable", languageCode: languageCode)
        case .onMyWay:
            return L10n.t("chat_structured_on_my_way_unavailable", languageCode: languageCode)
        case .poll:
            return L10n.t("chat_structured_poll_unavailable", languageCode: languageCode)
        case .profileShare, .pickupShare, .proShare, .venueShare:
            return L10n.t("chat_structured_item_unavailable", languageCode: languageCode)
        }
    }

    func logDecodeFailure(category: String) {
#if DEBUG
        print("[FanGeoStructuredChat] event=decodeFailed kind=\(rawValue) category=\(category)")
#endif
    }
}

/// Safe placeholder when a FanGeo sentinel is present but the payload cannot be decoded.
struct FanGeoStructuredUnavailableCard: View {
    let kind: FanGeoStructuredChatKind
    let languageCode: String
    var isFromCurrentUser: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .accessibilityHidden(true)
            Text(kind.unavailableTitle(languageCode: languageCode))
                .font(.subheadline)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 44)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(FGColor.cardBackground(colorScheme))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind.unavailableTitle(languageCode: languageCode))
    }
}
