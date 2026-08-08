import SwiftUI

/// Compact chat card for a structured FanGeo pickup-game share.
struct PickupGameShareChatCardView: View {
    let payload: PickupGameSharePayload
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

    private var sportLabel: String {
        AppSportCatalog.displayLabel(forSportToken: payload.sport)
    }

    private var whenLine: String? {
        payload.pickupDateWithCompactTimeRange(languageCode: languageCode)
    }

    private var placeLine: String? {
        let parts = [payload.placeName, payload.city, payload.region]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // Prefer address-aware placeName alone when it already includes city.
        if let place = payload.placeName?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty {
            let cityRegion = [payload.city, payload.region]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
            if !cityRegion.isEmpty, !place.localizedCaseInsensitiveContains(cityRegion) {
                return "\(place), \(cityRegion)"
            }
            return place
        }
        let joined = parts.joined(separator: ", ")
        return joined.isEmpty ? nil : joined
    }

    private var capacityLine: String? {
        guard let needed = payload.playersNeeded, needed > 0 else { return nil }
        let approved = max(0, payload.approvedJoinCount ?? 0)
        if let max = payload.maxPlayers, max > 0 {
            return "\(approved)/\(needed) · max \(max)"
        }
        return "\(approved)/\(needed)"
    }

    private var statusLabel: String? {
        switch payload.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "full":
            return L10n.t("share_pickup_status_full", languageCode: languageCode)
        case "cancelled", "canceled":
            return L10n.t("share_pickup_status_cancelled", languageCode: languageCode)
        case "active":
            return nil
        default:
            return nil
        }
    }

    private var organizerPreview: UserPreview {
        UserPreview(
            id: payload.pickupGameId,
            displayName: payload.organizerDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? L10n.t("share_pickup_organizer_fallback", languageCode: languageCode),
            username: nil,
            email: nil,
            avatarURL: payload.organizerAvatarThumbnailURL,
            avatarThumbnailURL: payload.organizerAvatarThumbnailURL
        )
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
                ProfileAvatarView(preview: organizerPreview, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(payload.title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    Text(sportLabel)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 4) {
                if let whenLine, !whenLine.isEmpty {
                    Label(whenLine, systemImage: "calendar")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
                if let placeLine, !placeLine.isEmpty {
                    Label(placeLine, systemImage: "mappin.and.ellipse")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
                if let organizer = payload.organizerDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines), !organizer.isEmpty {
                    Label(organizer, systemImage: "person.fill")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }
                if let capacityLine {
                    Label(capacityLine, systemImage: "person.3")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }
                if let statusLabel {
                    Text(statusLabel)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(statusLabelColor)
                        .lineLimit(1)
                }
            }

            Button {
                mapViewModel.presentSharedPickupGameDetail(gameId: payload.pickupGameId)
            } label: {
                Text(L10n.t("share_pickup_view_game", languageCode: languageCode))
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(FGColor.accentBlue, in: RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("share_pickup_view_game", languageCode: languageCode))
            .accessibilityHint(L10n.t("share_pickup_view_game_a11y_hint", languageCode: languageCode))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var statusLabelColor: Color {
        switch payload.status.lowercased() {
        case "cancelled", "canceled":
            return FGColor.dangerRed
        case "full":
            return Color.orange
        default:
            return FGColor.secondaryText(colorScheme)
        }
    }

    private var accessibilitySummary: String {
        var parts = [
            L10n.t("share_pickup_card_badge", languageCode: languageCode),
            payload.title,
            sportLabel
        ]
        if let whenLine { parts.append(whenLine) }
        if let placeLine { parts.append(placeLine) }
        if let statusLabel { parts.append(statusLabel) }
        return parts.joined(separator: ", ")
    }
}

private extension PickupGameSharePayload {
    func pickupDateWithCompactTimeRange(languageCode: String) -> String? {
        guard let start = PickupGameModels.parseSupabaseTimestamptz(gameStartAt) else { return nil }
        let locale = Locale(identifier: languageCode.replacingOccurrences(of: "-", with: "_"))
        let dateStyle = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(locale)
        let timeStyle = Date.FormatStyle.dateTime.hour().minute().locale(locale)
        let dateText = start.formatted(dateStyle)
        let end = endTime.flatMap { PickupGameModels.parseSupabaseTimestamptz($0) }
            ?? PickupGameModels.defaultPickupEndTime(forStart: start)
        if end > start {
            return "\(dateText) · \(start.formatted(timeStyle)) – \(end.formatted(timeStyle))"
        }
        return "\(dateText) · \(start.formatted(timeStyle))"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
