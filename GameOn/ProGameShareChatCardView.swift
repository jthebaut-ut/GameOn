import SwiftUI

/// Compact chat card for a structured FanGeo professional-game share.
struct ProGameShareChatCardView: View {
    let payload: ProGameSharePayload
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

    private var titleLine: String {
        "\(payload.awayTeam) at \(payload.homeTeam)"
    }

    private var whenLine: String? {
        guard let start = ProGameShareMessage.parseStartTime(payload.startTimeISO) else { return nil }
        return start.formatted(
            Date.FormatStyle.dateTime
                .month(.abbreviated)
                .day()
                .year()
                .hour()
                .minute()
                .locale(
                    Locale(
                        identifier: L10n.normalizedLanguageCode(languageCode)
                            .replacingOccurrences(of: "-", with: "_")
                    )
                )
        )
    }

    private var statusLabel: String {
        switch payload.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "final":
            return L10n.t("share_pro_game_status_final", languageCode: languageCode)
        case "live":
            return L10n.t("share_pro_game_status_live", languageCode: languageCode)
        default:
            return L10n.t("share_pro_game_status_upcoming", languageCode: languageCode)
        }
    }

    private var scoreLine: String? {
        guard let home = payload.scoreHome, let away = payload.scoreAway else { return nil }
        return "\(payload.awayTeam) \(away) – \(home) \(payload.homeTeam)"
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
                Image(systemName: "sportscourt.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(FGColor.accentGreen)
                    .frame(width: 42, height: 42)
                    .background(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.20 : 0.12), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(titleLine)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    Text("\(sportLabel) · \(payload.league)")
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
                if let venue = payload.venueName?.trimmingCharacters(in: .whitespacesAndNewlines), !venue.isEmpty {
                    Label(venue, systemImage: "mappin.and.ellipse")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(2)
                }
                if let scoreLine {
                    Label(scoreLine, systemImage: "sportscourt")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
                Text(statusLabel)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(statusLabelColor)
                    .lineLimit(1)
            }

            Button {
                mapViewModel.presentSharedProGameDetail(payload: payload)
            } label: {
                Text(L10n.t("share_pro_game_view_game", languageCode: languageCode))
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(FGColor.accentBlue, in: RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("share_pro_game_view_game", languageCode: languageCode))
            .accessibilityHint(L10n.t("share_pro_game_view_game_a11y_hint", languageCode: languageCode))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var statusLabelColor: Color {
        switch payload.status.lowercased() {
        case "final":
            return FGColor.secondaryText(colorScheme)
        case "live":
            return FGColor.dangerRed
        default:
            return FGColor.accentGreen
        }
    }

    private var accessibilitySummary: String {
        var parts = [
            L10n.t("share_pro_game_card_badge", languageCode: languageCode),
            titleLine,
            sportLabel,
            statusLabel
        ]
        if let whenLine { parts.append(whenLine) }
        if let scoreLine { parts.append(scoreLine) }
        return parts.joined(separator: ", ")
    }
}
