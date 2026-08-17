import SwiftUI

// MARK: - Lineup visual language (neutral FanGeo blue — not Team color)

/// Stable accent for Event Lineup surfaces. Never inherits Team `colorHex`.
enum FanTeamLineupAppearance {
    static var accent: Color { FGColor.accentBlue }

    /// Draft status — distinguishable from Published without Team color.
    static var draftAccent: Color { FGColor.accentYellow }

    static func statusAccent(isPublished: Bool) -> Color {
        isPublished ? accent : draftAccent
    }

    static func softFill(_ colorScheme: ColorScheme, accent: Color = accent) -> Color {
        accent.opacity(colorScheme == .dark ? 0.22 : 0.12)
    }

    static func softSurface(_ colorScheme: ColorScheme) -> Color {
        accent.opacity(colorScheme == .dark ? 0.12 : 0.07)
    }

    static func highlightFill(_ colorScheme: ColorScheme) -> Color {
        accent.opacity(colorScheme == .dark ? 0.10 : 0.05)
    }

    static func highlightStroke(_ colorScheme: ColorScheme) -> Color {
        accent.opacity(colorScheme == .dark ? 0.30 : 0.20)
    }
}

// MARK: - Player / parent published list leafs
// Answers: “Where is my player?” — no formation / Starting / Bench chrome.

/// Position-first row for the published Lineup sheet (Apple Contacts–like scan).
struct FanTeamEventLineupPlayerParentRowView: View {
    let player: FanTeamLineupPlayerPresentation
    let sportToken: String
    let languageCode: String
    var accent: Color = FanTeamLineupAppearance.accent

    @Environment(\.colorScheme) private var colorScheme

    private var badge: String {
        FanTeamLineupPresentation.playerParentPositionBadge(
            player: player,
            sportToken: sportToken,
            languageCode: languageCode
        )
    }

    private var positionTitle: String {
        FanTeamLineupPresentation.playerParentPositionTitle(
            player: player,
            sportToken: sportToken,
            languageCode: languageCode
        )
    }

    private var isHighlighted: Bool {
        FanTeamLineupPresentation.isHighlightedForViewer(player)
    }

    private var avatarFallback: UserAvatarView.FallbackStyle {
        colorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            positionBadge

            UserAvatarView(
                avatarThumbnailURL: player.avatarThumbnailURL,
                avatarURL: player.avatarURL ?? "",
                avatarDisplayRefreshToken: .init(),
                displayName: player.displayName,
                email: "",
                size: 44,
                fallbackStyle: avatarFallback
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(positionTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)

                Text(player.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if isHighlighted {
                    Text(L10n.t(FanTeamLineupPresentation.viewerHighlightLabelKey(), languageCode: languageCode))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(accent)
                } else if let number = player.numberLabel {
                    Text(number)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                .fill(
                    isHighlighted
                        ? FanTeamLineupAppearance.highlightFill(colorScheme)
                        : FGAdaptiveSurface.cardElevated(colorScheme).opacity(colorScheme == .dark ? 0.92 : 0.98)
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                .strokeBorder(
                    isHighlighted
                        ? FanTeamLineupAppearance.highlightStroke(colorScheme)
                        : FGColor.divider(colorScheme).opacity(0.35),
                    lineWidth: 1
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var positionBadge: some View {
        Text(badge)
            .font(.caption.weight(.bold))
            .foregroundStyle(accent)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(minWidth: 40)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                FanTeamLineupAppearance.softFill(colorScheme, accent: accent),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        var parts = [positionTitle, player.displayName]
        if isHighlighted {
            parts.append(L10n.t(FanTeamLineupPresentation.viewerHighlightLabelKey(), languageCode: languageCode))
        } else if let number = player.playerNumber {
            parts.append(
                String(
                    format: L10n.t("fan_teams_player_number_a11y_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    Int64(number)
                )
            )
        }
        return parts.joined(separator: ", ")
    }
}

struct FanTeamEventLineupPublishedHeaderView: View {
    let languageCode: String
    var accent: Color = FanTeamLineupAppearance.accent

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
                Text(L10n.t("fan_team_lineup_published_short", languageCode: languageCode))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(accent)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(FanTeamLineupAppearance.softFill(colorScheme, accent: accent))
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L10n.t("fan_team_lineup_published_short", languageCode: languageCode))

            Text(L10n.t("fan_team_lineup_published_by_team", languageCode: languageCode))
                .font(.subheadline)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct FanTeamEventLineupPublishedEmptyStateView: View {
    let languageCode: String
    var accent: Color = FanTeamLineupAppearance.accent

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 40)
            ZStack {
                Circle()
                    .fill(FanTeamLineupAppearance.softFill(colorScheme, accent: accent))
                    .frame(width: 108, height: 108)
                Image(systemName: "list.bullet.rectangle.portrait")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .accessibilityHidden(true)

            Text(L10n.t("fan_team_lineup_not_published_yet", languageCode: languageCode))
                .font(FGTypography.sectionTitle)
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FanTeamEventLineupPublishedFooterNote: View {
    let languageCode: String
    var accent: Color = FanTeamLineupAppearance.accent

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accent.opacity(colorScheme == .dark ? 0.90 : 0.85))
                .accessibilityHidden(true)
            Text(L10n.t("fan_team_lineup_positions_manager_note", languageCode: languageCode))
                .font(.footnote)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                .fill(FanTeamLineupAppearance.softSurface(colorScheme))
        }
        .accessibilityElement(children: .combine)
    }
}
