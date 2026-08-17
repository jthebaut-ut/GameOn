import SwiftUI

// MARK: - Standalone Pickup detail leaves
//
// Visual restyle to match Team Event Details hierarchy and chrome, with
// orange Pickup identity. Host: `DiscoverPickupGameDetailSheet` standalone
// branch only. Does not change Team Event layout or join/RSVP business logic.

enum PickupGameDetailPresentation {
    static let accent = FGColor.intentPlay

    static func sectionHeader(
        _ title: String,
        colorScheme: ColorScheme
    ) -> some View {
        Text(title)
            .font(FGTypography.caption.weight(.bold))
            .foregroundStyle(FGColor.secondaryText(colorScheme))
            .textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Hero

struct PickupGameDetailHeroCard: View {
    let game: PickupGameRow
    let sportLabel: String
    let languageCode: String
    let showStarted: Bool
    let onShowOnMap: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color { PickupGameDetailPresentation.accent }
    private var mainInk: Color { FGColor.primaryText(colorScheme) }
    private var subInk: Color { FGColor.secondaryText(colorScheme) }

    private var eventTitle: String {
        let title = game.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty
            ? L10n.t("share_pickup_card_badge", languageCode: languageCode)
            : title
    }

    private var formatTitle: String {
        game.gameFormat.displayTitle(languageCode: languageCode)
    }

    var body: some View {
        TeamEventPlayerCardChrome(tint: accent.opacity(0.55)) {
            Button(action: onShowOnMap) {
                HStack(alignment: .top, spacing: FGSpacing.md) {
                    PickupGameStartedSportGlyphFrame(showStarted: showStarted) {
                        SportArtworkIconView(sport: game.sport, diameter: 72)
                    }
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: FGSpacing.sm) {
                            GameFormatBadgeView(
                                format: game.gameFormat,
                                colorScheme: colorScheme,
                                accent: accent
                            )
                            PickupGameVisibilityBadge(
                                isVisible: game.is_visible,
                                languageCode: languageCode,
                                colorScheme: colorScheme
                            )
                            if showStarted {
                                startedPill
                            }
                        }

                        Text(eventTitle)
                            .font(.system(.title3, design: .rounded).weight(.bold))
                            .foregroundStyle(mainInk)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(formatTitle)
                            .font(FGTypography.metadata.weight(.semibold))
                            .foregroundStyle(accent)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 6) {
                            Image(systemName: SportFilterCatalog.resolve(game.sport).systemImage)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(subInk)
                                .accessibilityHidden(true)
                            Text(sportLabel)
                                .font(FGTypography.metadata.weight(.medium))
                                .foregroundStyle(subInk)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(heroAccessibilityLabel)
            .accessibilityHint(L10n.t("discover_pickup_show_on_map_a11y_hint", languageCode: languageCode))
        }
    }

    private var startedPill: some View {
        Text(L10n.t("team_event_status_started", languageCode: languageCode))
            .font(.caption2.weight(.bold))
            .foregroundStyle(subInk)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(FGColor.secondaryText(colorScheme).opacity(colorScheme == .dark ? 0.18 : 0.10))
            )
    }

    private var heroAccessibilityLabel: String {
        let privacy = game.is_visible
            ? L10n.t("pickup_form_visibility_public", languageCode: languageCode)
            : L10n.t("pickup_form_visibility_private", languageCode: languageCode)
        var parts = [
            L10n.t("share_pickup_card_badge", languageCode: languageCode),
            privacy,
            eventTitle,
            formatTitle,
            sportLabel,
        ]
        if showStarted {
            parts.append(L10n.t("team_event_status_started", languageCode: languageCode))
        }
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
    }
}

// MARK: - My Response (join / request — same chrome as Team Event RSVP)

struct PickupGameDetailMyResponseCard: View {
    enum Status: Equatable {
        case signedOut
        case businessGated
        case none
        case pending
        case going
        case cantGo
        case full
    }

    let status: Status
    let languageCode: String
    var statusTitle: String? = nil
    let isBusy: Bool
    let showsJoinCTA: Bool
    let onJoin: () -> Void
    let onChangeResponse: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color { PickupGameDetailPresentation.accent }
    private var mainInk: Color { FGColor.primaryText(colorScheme) }
    private var subInk: Color { FGColor.secondaryText(colorScheme) }

    private var cardTint: Color? {
        switch status {
        case .going: return FGColor.accentGreen
        case .pending: return FGColor.accentYellow
        case .cantGo: return FGColor.dangerRed
        case .signedOut, .businessGated, .none, .full: return nil
        }
    }

    var body: some View {
        TeamEventPlayerCardChrome(tint: cardTint) {
            Group {
                switch status {
                case .signedOut:
                    promptBody(
                        title: L10n.t(
                            "Sign in to request to join this pickup game.",
                            languageCode: languageCode
                        )
                    )
                case .businessGated:
                    promptBody(title: BusinessFanGateCopy.pickupFanOnly)
                case .full:
                    promptBody(
                        title: L10n.t("No more players needed.", languageCode: languageCode)
                    )
                case .none:
                    joinBody
                case .pending:
                    confirmedBody(
                        title: statusTitle
                            ?? L10n.t("Your request", languageCode: languageCode),
                        color: FGColor.accentYellow,
                        icon: "questionmark.circle.fill"
                    )
                case .going:
                    confirmedBody(
                        title: L10n.t("team_event_youre_going", languageCode: languageCode),
                        color: FGColor.accentGreen,
                        icon: "checkmark.circle.fill"
                    )
                case .cantGo:
                    if showsJoinCTA {
                        joinBody
                    } else {
                        confirmedBody(
                            title: L10n.t("team_event_you_cant_go", languageCode: languageCode),
                            color: FGColor.dangerRed,
                            icon: "xmark.circle.fill"
                        )
                    }
                }
            }
            .opacity(isBusy ? 0.55 : 1)
            .overlay {
                if isBusy { ProgressView() }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func promptBody(title: String) -> some View {
        Text(title)
            .font(FGTypography.metadata.weight(.semibold))
            .foregroundStyle(subInk)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var joinBody: some View {
        VStack(alignment: .leading, spacing: FGSpacing.sm) {
            Button(action: onJoin) {
                Text(L10n.t("Request to Join", languageCode: languageCode))
                    .font(FGTypography.cardTitle.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                            .fill(accent)
                    )
            }
            .buttonStyle(.plain)
            .disabled(isBusy)

            Text(L10n.t("You’ll be visible to other players once you join.", languageCode: languageCode))
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
        }
    }

    private func confirmedBody(title: String, color: Color, icon: String) -> some View {
        Button(action: onChangeResponse) {
            HStack(spacing: FGSpacing.md) {
                Image(systemName: icon)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(FGTypography.metadata.weight(.bold))
                        .foregroundStyle(color)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.t("team_event_change_your_response", languageCode: languageCode))
                        .font(FGTypography.caption.weight(.medium))
                        .foregroundStyle(subInk)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel(
            "\(title). \(L10n.t("team_event_change_your_response", languageCode: languageCode))"
        )
    }
}

// MARK: - Who's Going (compact Team Event pattern, orange View all)

struct PickupGameDetailWhosGoingCard: View {
    let languageCode: String
    let stackMembers: [PickupGameRosterMember]
    let goingCount: Int
    let maybeCount: Int
    let cantGoCount: Int
    let spotsNeededLine: String?
    let onViewAll: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color { PickupGameDetailPresentation.accent }
    private var mainInk: Color { FGColor.primaryText(colorScheme) }
    private var subInk: Color { FGColor.secondaryText(colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: FGSpacing.sm) {
            HStack {
                PickupGameDetailPresentation.sectionHeader(
                    L10n.t("pickup_detail_whos_going", languageCode: languageCode),
                    colorScheme: colorScheme
                )
                Spacer(minLength: 0)
                Button(action: onViewAll) {
                    Text(L10n.t("View all", languageCode: languageCode))
                        .font(FGTypography.caption.weight(.bold))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
            }

            Button(action: onViewAll) {
                TeamEventPlayerCardChrome {
                    VStack(alignment: .leading, spacing: FGSpacing.md) {
                        if !stackMembers.isEmpty {
                            PickupPlayingAvatarStack(
                                members: stackMembers,
                                maxVisible: 5,
                                diameter: 34
                            )
                            .accessibilityHidden(true)
                        } else {
                            Text(L10n.t("team_event_whos_going_empty", languageCode: languageCode))
                                .font(FGTypography.caption.weight(.medium))
                                .foregroundStyle(subInk)
                        }

                        HStack(spacing: FGSpacing.md) {
                            attendanceStat(
                                systemImage: "checkmark.circle.fill",
                                tint: FGColor.accentGreen,
                                count: goingCount,
                                label: L10n.t("Going", languageCode: languageCode)
                            )
                            attendanceStat(
                                systemImage: "questionmark.circle.fill",
                                tint: FGColor.accentYellow,
                                count: maybeCount,
                                label: L10n.t("Maybe", languageCode: languageCode)
                            )
                            if cantGoCount > 0 {
                                attendanceStat(
                                    systemImage: "xmark.circle.fill",
                                    tint: FGColor.dangerRed,
                                    count: cantGoCount,
                                    label: L10n.t("fan_team_rsvp_cant_go", languageCode: languageCode)
                                )
                            }
                        }

                        if let spotsNeededLine, !spotsNeededLine.isEmpty {
                            Text(spotsNeededLine)
                                .font(FGTypography.caption)
                                .foregroundStyle(subInk)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityHint(
                L10n.t("pickup_detail_view_responses_a11y_hint", languageCode: languageCode)
            )
            .accessibilityAddTraits(.isButton)
        }
    }

    private func attendanceStat(
        systemImage: String,
        tint: Color,
        count: Int,
        label: String
    ) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
            Text("\(count)")
                .font(FGTypography.metadata.weight(.bold))
                .foregroundStyle(mainInk)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(subInk)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) \(label)")
    }

    private var accessibilitySummary: String {
        var parts = [L10n.t("pickup_detail_whos_going", languageCode: languageCode)]
        parts.append("\(goingCount) \(L10n.t("Going", languageCode: languageCode))")
        parts.append("\(maybeCount) \(L10n.t("Maybe", languageCode: languageCode))")
        if cantGoCount > 0 {
            parts.append("\(cantGoCount) \(L10n.t("fan_team_rsvp_cant_go", languageCode: languageCode))")
        }
        return parts.joined(separator: ". ")
    }
}

// MARK: - Description

struct PickupGameDetailDescriptionCard: View {
    let description: String?
    let languageCode: String

    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color { PickupGameDetailPresentation.accent }
    private var trimmed: String {
        (description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        TeamEventPlayerCardChrome {
            VStack(alignment: .leading, spacing: FGSpacing.sm) {
                HStack(spacing: 8) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                    Text(L10n.t("pickup_form_description", languageCode: languageCode))
                        .font(FGTypography.caption.weight(.bold))
                        .foregroundStyle(accent)
                        .textCase(.uppercase)
                }
                .accessibilityAddTraits(.isHeader)

                if trimmed.isEmpty {
                    Text(L10n.t("pickup_detail_no_description", languageCode: languageCode))
                        .font(FGTypography.caption.weight(.medium))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(trimmed)
                        .font(FGTypography.body)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            trimmed.isEmpty
                ? "\(L10n.t("pickup_form_description", languageCode: languageCode)). \(L10n.t("pickup_detail_no_description", languageCode: languageCode))"
                : "\(L10n.t("pickup_form_description", languageCode: languageCode)). \(trimmed)"
        )
    }
}

// MARK: - Organizer

struct PickupGameDetailOrganizerCard: View {
    let displayName: String
    let thumbnailURL: String?
    let fullURL: String?
    let refreshToken: UUID?
    let summaryLine: String?
    let languageCode: String
    let onOpenProfile: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color { PickupGameDetailPresentation.accent }
    private var mainInk: Color { FGColor.primaryText(colorScheme) }
    private var subInk: Color { FGColor.secondaryText(colorScheme) }
    private var avatarFallback: UserAvatarView.FallbackStyle {
        colorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FGSpacing.sm) {
            PickupGameDetailPresentation.sectionHeader(
                L10n.t("Organizer", languageCode: languageCode),
                colorScheme: colorScheme
            )

            Button(action: onOpenProfile) {
                TeamEventPlayerCardChrome {
                    HStack(alignment: .center, spacing: FGSpacing.md) {
                        UserAvatarView(
                            avatarThumbnailURL: thumbnailURL,
                            avatarURL: fullURL ?? "",
                            avatarDisplayRefreshToken: refreshToken ?? UUID(),
                            displayName: displayName,
                            email: "",
                            size: 44,
                            fallbackStyle: avatarFallback,
                            imagePlaceholderTint: colorScheme == .dark ? .white.opacity(0.75) : nil
                        )
                        .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(displayName)
                                .font(FGTypography.metadata.weight(.bold))
                                .foregroundStyle(mainInk)
                                .lineLimit(2)
                            if let summaryLine, !summaryLine.isEmpty {
                                Text(summaryLine)
                                    .font(FGTypography.caption)
                                    .foregroundStyle(subInk)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(FGColor.mutedText(colorScheme))
                            .accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint(L10n.t("live_pickup_organizer_a11y_hint", languageCode: languageCode))
        }
    }
}
