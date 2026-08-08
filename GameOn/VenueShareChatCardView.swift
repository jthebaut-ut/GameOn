import SwiftUI

/// Compact chat card for a structured FanGeo favorite-spot / venue share.
struct VenueShareChatCardView: View {
    let payload: VenueSharePayload
    let isFromCurrentUser: Bool
    let showFriendAvatar: Bool
    let friendPreview: UserPreview
    let timestamp: String?
    @ObservedObject var mapViewModel: MapViewModel

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var locationLine: String? {
        VenueShareMessage.locationLine(for: payload)
    }

    private var imageURL: String? {
        payload.coverPhotoThumbnailURL ?? payload.coverPhotoURL
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: FGSpacing.sm) {
            if !isFromCurrentUser, showFriendAvatar {
                ProfileAvatarView(preview: friendPreview, size: 30)
                    .frame(width: 34, alignment: .center)
            } else if !isFromCurrentUser {
                Color.clear
                    .frame(width: 34, height: 1)
            }

            VStack(alignment: isFromCurrentUser ? .trailing : .leading, spacing: FGSpacing.xs + 1) {
                cardContent
                    .frame(maxWidth: 280, alignment: .leading)
                    .padding(.horizontal, FGSpacing.md)
                    .padding(.vertical, FGSpacing.sm + 2)
                    .background {
                        RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                            .fill(FGColor.cardBackground(colorScheme))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                            .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                    }
                    .softCardShadow()

                if let timestamp, !timestamp.isEmpty {
                    Text(timestamp)
                        .font(FGTypography.metadata)
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .padding(.horizontal, FGSpacing.xs)
                        .frame(maxWidth: .infinity, alignment: isFromCurrentUser ? .trailing : .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: isFromCurrentUser ? .trailing : .leading)
            .padding(.leading, isFromCurrentUser ? 52 : 0)
            .padding(.trailing, isFromCurrentUser ? 0 : 52)

            if isFromCurrentUser {
                Color.clear
                    .frame(width: 34, height: 1)
            }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                venueThumb
                VStack(alignment: .leading, spacing: 2) {
                    Text(payload.name)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    Text(L10n.t("share_favorite_spot_card_badge", languageCode: languageCode))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 4) {
                if let locationLine, !locationLine.isEmpty {
                    Label(locationLine, systemImage: "mappin.and.ellipse")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
                if let venueType = payload.venueType?.trimmingCharacters(in: .whitespacesAndNewlines), !venueType.isEmpty {
                    Label(venueType.capitalized, systemImage: "building.2")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }
                if let events = payload.hostedEventTitles, !events.isEmpty {
                    Label(events.joined(separator: " · "), systemImage: "tv.fill")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
            }

            Button {
                mapViewModel.presentSharedVenueDetail(payload: payload)
            } label: {
                Text(L10n.t("share_favorite_spot_view", languageCode: languageCode))
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(FGColor.accentBlue, in: RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("share_favorite_spot_view", languageCode: languageCode))
            .accessibilityHint(L10n.t("share_favorite_spot_view_a11y_hint", languageCode: languageCode))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private var venueThumb: some View {
        if let urlString = imageURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    placeholderThumb
                }
            }
            .frame(width: 42, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            placeholderThumb
        }
    }

    private var placeholderThumb: some View {
        Image(systemName: "building.2.fill")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(FGColor.accentGreen)
            .frame(width: 42, height: 42)
            .background(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.20 : 0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var accessibilitySummary: String {
        var parts = [
            L10n.t("share_favorite_spot_card_badge", languageCode: languageCode),
            payload.name
        ]
        if let locationLine { parts.append(locationLine) }
        return parts.joined(separator: ", ")
    }
}
