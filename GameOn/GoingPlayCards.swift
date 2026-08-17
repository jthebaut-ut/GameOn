import SwiftUI

/// Light-fill source chip: green PICKUP / purple TEAM, matching the approved mockup.
struct GoingPlaySourceBadge: View {
    let source: GoingPlaySource
    let languageCode: String
    let colorScheme: ColorScheme

    private var title: String {
        switch source {
        case .pickup:
            return L10n.t("going_play_badge_pickup", languageCode: languageCode)
        case .team:
            return L10n.t("going_play_badge_team", languageCode: languageCode)
        }
    }

    private var tint: Color {
        switch source {
        case .pickup: return FGColor.accentGreen
        case .team: return FGColor.intentTeams
        }
    }

    private var symbol: String {
        switch source {
        case .pickup: return "figure.run"
        case .team: return "shield.fill"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .tracking(0.3)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(colorScheme == .dark ? 0.22 : 0.14), in: Capsule(style: .continuous))
        .accessibilityLabel(
            source == .pickup
                ? L10n.t("going_play_a11y_pickup", languageCode: languageCode)
                : L10n.t("going_play_a11y_team", languageCode: languageCode)
        )
    }
}

struct GoingPlayStatusBadge: View {
    let state: GoingPlayParticipationState
    let languageCode: String
    let colorScheme: ColorScheme

    var body: some View {
        let title = L10n.t(state.titleKey(), languageCode: languageCode)
        Text(title)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(background, in: Capsule(style: .continuous))
            .accessibilityLabel(title)
    }

    private var foreground: Color {
        switch state {
        case .approved, .going:
            return FGColor.accentGreen
        case .pending, .invited, .started:
            return Color.orange.opacity(colorScheme == .dark ? 0.95 : 0.88)
        case .full:
            return Color.orange.opacity(colorScheme == .dark ? 0.95 : 0.82)
        case .declined:
            return FGColor.secondaryText(colorScheme)
        case .completed:
            return FGColor.mutedText(colorScheme)
        }
    }

    private var background: Color {
        switch state {
        case .approved, .going:
            return FGColor.accentGreen.opacity(colorScheme == .dark ? 0.20 : 0.14)
        case .pending, .invited, .started:
            return Color.orange.opacity(colorScheme == .dark ? 0.18 : 0.12)
        case .full:
            return Color.orange.opacity(colorScheme == .dark ? 0.16 : 0.10)
        case .declined, .completed:
            return Color.gray.opacity(colorScheme == .dark ? 0.22 : 0.12)
        }
    }
}

struct GoingPlayStatusChipRow: View {
    let source: GoingPlaySource
    let isFull: Bool
    let participation: GoingPlayParticipationState?
    let languageCode: String
    let colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: 6) {
            GoingPlaySourceBadge(
                source: source,
                languageCode: languageCode,
                colorScheme: colorScheme
            )
            if isFull, participation != .full {
                GoingPlayStatusBadge(
                    state: .full,
                    languageCode: languageCode,
                    colorScheme: colorScheme
                )
            }
            if let participation, participation != .full || !isFull {
                GoingPlayStatusBadge(
                    state: participation,
                    languageCode: languageCode,
                    colorScheme: colorScheme
                )
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Compact Team event card for Going → Play.
struct GoingPlayTeamCard<Overflow: View>: View {
    let item: GoingPlayFeedItem
    let dateTimeLine: String
    let languageCode: String
    let colorScheme: ColorScheme
    let overflow: Overflow
    let onOpen: () -> Void
    let onViewEvent: () -> Void

    init(
        item: GoingPlayFeedItem,
        dateTimeLine: String,
        languageCode: String,
        colorScheme: ColorScheme,
        onOpen: @escaping () -> Void,
        onViewEvent: @escaping () -> Void,
        @ViewBuilder overflow: () -> Overflow
    ) {
        self.item = item
        self.dateTimeLine = dateTimeLine
        self.languageCode = languageCode
        self.colorScheme = colorScheme
        self.onOpen = onOpen
        self.onViewEvent = onViewEvent
        self.overflow = overflow()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                mark
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    GoingPlayStatusChipRow(
                        source: .team,
                        isFull: item.isFull,
                        participation: item.participation,
                        languageCode: languageCode,
                        colorScheme: colorScheme
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                overflow
            }

            if !dateTimeLine.isEmpty {
                Label(dateTimeLine, systemImage: "calendar")
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .labelStyle(.titleAndIcon)
                    .accessibilityHidden(true)
            }
            if !item.locationLine.isEmpty {
                Label(item.locationLine, systemImage: "mappin.and.ellipse")
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(2)
                    .labelStyle(.titleAndIcon)
                    .accessibilityHidden(true)
            }

            if !item.viaManagedPlayerNames.isEmpty {
                Text(
                    String(
                        format: L10n.t("fan_teams_relationship_via", languageCode: languageCode),
                        locale: Locale(identifier: L10n.normalizedLanguageCode(languageCode)),
                        item.viaManagedPlayerNames.joined(separator: ", ")
                    )
                )
                .font(FGTypography.metadata)
                .foregroundStyle(FGColor.mutedText(colorScheme))
            }

            HStack(alignment: .center, spacing: 8) {
                footerIdentity
                Spacer(minLength: 8)
                Button(action: onViewEvent) {
                    Text(L10n.t("action_center_cta_view_event", languageCode: languageCode))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(FGColor.accentBlue, in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .frame(minHeight: 36)
                .accessibilityLabel(L10n.t("action_center_cta_view_event", languageCode: languageCode))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground).opacity(colorScheme == .dark ? 0.55 : 0.96))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.45), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            GoingPlayProjection.accessibilityLabel(
                item: item,
                dateTimeLine: dateTimeLine,
                languageCode: languageCode
            )
        )
    }

    private var mark: some View {
        let sportToken = item.teamIdentity?.teamSport ?? item.sport
        let visual = SportFilterCatalog.resolve(sportToken)
        return Image(systemName: visual.systemImage)
            .font(.body.weight(.semibold))
            .foregroundStyle(visual.accent)
            .frame(width: 36, height: 36)
            .background(visual.accent.opacity(0.14), in: Circle())
    }

    private var footerIdentity: some View {
        HStack(spacing: 8) {
            FanTeamMarkView(
                sport: item.teamIdentity?.teamSport ?? item.sport,
                logoURL: item.teamIdentity?.logoURL,
                logoThumbnailURL: item.teamIdentity?.logoThumbnailURL,
                colorHex: item.teamIdentity?.colorHex,
                size: 28,
                displayRefreshToken: item.teamIdentity?.displayRefreshToken
            )
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.teamIdentity?.teamName ?? item.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    GoingPlayProjection.teamFooterSubtitle(
                        format: item.eventType,
                        sport: item.sport,
                        sportSubtype: item.sportSubtype,
                        languageCode: languageCode
                    )
                )
                .font(FGTypography.metadata)
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .lineLimit(1)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Compact Pickup card for Going → Play (join or hosted).
struct GoingPlayPickupCard<Overflow: View, Extra: View>: View {
    let item: GoingPlayFeedItem
    let dateTimeLine: String
    let locationLine: String
    let spotsLine: String?
    let organizerName: String?
    let showStarted: Bool
    let languageCode: String
    let colorScheme: ColorScheme
    let overflow: Overflow
    let extra: Extra
    let onOpen: () -> Void
    let onViewDetails: () -> Void
    let organizerAvatar: AnyView?

    init(
        item: GoingPlayFeedItem,
        dateTimeLine: String,
        locationLine: String,
        spotsLine: String?,
        organizerName: String?,
        showStarted: Bool,
        languageCode: String,
        colorScheme: ColorScheme,
        organizerAvatar: AnyView? = nil,
        onOpen: @escaping () -> Void,
        onViewDetails: @escaping () -> Void,
        @ViewBuilder overflow: () -> Overflow,
        @ViewBuilder extra: () -> Extra
    ) {
        self.item = item
        self.dateTimeLine = dateTimeLine
        self.locationLine = locationLine
        self.spotsLine = spotsLine
        self.organizerName = organizerName
        self.showStarted = showStarted
        self.languageCode = languageCode
        self.colorScheme = colorScheme
        self.organizerAvatar = organizerAvatar
        self.onOpen = onOpen
        self.onViewDetails = onViewDetails
        self.overflow = overflow()
        self.extra = extra()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                PickupGameStartedSportGlyphFrame(showStarted: showStarted) {
                    let visual = SportFilterCatalog.resolve(item.sport)
                    Image(systemName: visual.systemImage)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(visual.accent)
                        .frame(width: 36, height: 36)
                        .background(visual.accent.opacity(0.14), in: Circle())
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    GoingPlayStatusChipRow(
                        source: .pickup,
                        isFull: item.isFull,
                        participation: item.participation,
                        languageCode: languageCode,
                        colorScheme: colorScheme
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                overflow
            }

            if !dateTimeLine.isEmpty {
                Label(dateTimeLine, systemImage: "calendar")
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .labelStyle(.titleAndIcon)
                    .accessibilityHidden(true)
            }
            if !locationLine.isEmpty {
                Label(locationLine, systemImage: "mappin.and.ellipse")
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(2)
                    .labelStyle(.titleAndIcon)
                    .accessibilityHidden(true)
            }

            if organizerName != nil || organizerAvatar != nil {
                HStack(spacing: 8) {
                    if let organizerAvatar {
                        organizerAvatar
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.t("Organizer", languageCode: languageCode))
                            .font(FGTypography.metadata)
                            .foregroundStyle(FGColor.mutedText(colorScheme))
                        if let organizerName, !organizerName.isEmpty {
                            Text(organizerName)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityHidden(true)
            }

            extra

            if let spotsLine, !spotsLine.isEmpty {
                Text(spotsLine)
                    .font(FGTypography.metadata)
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            }

            Button(action: onViewDetails) {
                Text(L10n.t("View Details", languageCode: languageCode))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.accentBlue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        FGColor.accentBlue.opacity(colorScheme == .dark ? 0.22 : 0.12),
                        in: Capsule(style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .frame(minHeight: 40)
            .accessibilityLabel(L10n.t("View Details", languageCode: languageCode))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground).opacity(colorScheme == .dark ? 0.55 : 0.96))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.45), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            GoingPlayProjection.accessibilityLabel(
                item: item,
                dateTimeLine: dateTimeLine,
                languageCode: languageCode
            )
        )
    }
}
