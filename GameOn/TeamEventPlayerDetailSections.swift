import SwiftUI

// MARK: - Team Event player/parent detail leaves
//
// Kept out of DiscoverScreen / giant JoinFlow `@ViewBuilder` chains.
// Host: `DiscoverPickupGameDetailSheet` Team-linked branch only.
// Visual redesign target: richer Event Details hierarchy (hero → when/where →
// RSVP → who’s going → lineup → more). Behavior/permissions stay in the host.

enum TeamEventPlayerDetailPresentation {
    /// Past when scheduled end (or start+2h) has elapsed.
    static func isPastEvent(_ game: PickupGameRow, now: Date = Date()) -> Bool {
        guard let end = PickupGameModels.endDate(for: game) else {
            return game.hasPickupGameStarted(now: now)
        }
        return now >= end
    }

    static func showsInteractiveRSVP(
        game: PickupGameRow,
        isCancelled: Bool,
        isExcluded: Bool,
        now: Date = Date()
    ) -> Bool {
        guard !isCancelled, !isExcluded else { return false }
        return !isPastEvent(game, now: now)
    }

    /// Bottom Invite / Chat / Share CTAs are for standalone Pickup only.
    /// Team-linked Event Detail keeps Invite in the toolbar … menu and Chat on Team Detail.
    static func showsBottomSocialActionRow(isTeamLinked: Bool) -> Bool {
        !isTeamLinked
    }

    static func weekdayDateText(for game: PickupGameRow, languageCode: String) -> String {
        guard let start = PickupGameModels.parseSupabaseTimestamptz(game.game_start_at) else { return "" }
        let locale = Locale(identifier: languageCode.replacingOccurrences(of: "-", with: "_"))
        return start.formatted(
            Date.FormatStyle()
                .weekday(.abbreviated)
                .month(.abbreviated)
                .day()
                .year()
                .locale(locale)
        )
    }

    static func timeRangeText(for game: PickupGameRow, languageCode: String) -> String? {
        guard let start = PickupGameModels.parseSupabaseTimestamptz(game.game_start_at) else { return nil }
        let locale = Locale(identifier: languageCode.replacingOccurrences(of: "-", with: "_"))
        let timeStyle = Date.FormatStyle.dateTime.hour().minute().locale(locale)
        if let end = PickupGameModels.endDate(for: game), end > start {
            return "\(start.formatted(timeStyle)) – \(end.formatted(timeStyle))"
        }
        return start.formatted(timeStyle)
    }

    /// First-person RSVP headline for the viewer’s own seat (managed seats keep named copy).
    static func firstPersonConfirmedTitle(
        state: FanTeamScheduleQuickRSVPState,
        languageCode: String
    ) -> String {
        switch state {
        case .going:
            return L10n.t("team_event_youre_going", languageCode: languageCode)
        case .maybe:
            return L10n.t("team_event_youre_maybe", languageCode: languageCode)
        case .cantGo:
            return L10n.t("team_event_you_cant_go", languageCode: languageCode)
        case .noResponse:
            return L10n.t("team_event_change_your_response", languageCode: languageCode)
        }
    }
}

// MARK: - Shared card chrome

struct TeamEventPlayerCardChrome<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    var tint: Color? = nil
    var padded: Bool = true
    let content: Content

    init(
        tint: Color? = nil,
        padded: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.tint = tint
        self.padded = padded
        self.content = content()
    }

    var body: some View {
        content
            .padding(padded ? FGSpacing.md : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { cardFill }
            .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: 1)
            }
    }

    @ViewBuilder
    private var cardFill: some View {
        ZStack {
            RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                .fill(FGColor.cardBackground(colorScheme))
            RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                .fill(.ultraThinMaterial.opacity(colorScheme == .dark ? 0.55 : 0.35))
            if let tint {
                RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                    .fill(tint.opacity(colorScheme == .dark ? 0.16 : 0.10))
            }
        }
    }

    private var strokeColor: Color {
        if let tint {
            return tint.opacity(colorScheme == .dark ? 0.38 : 0.22)
        }
        return FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.55 : 0.45)
    }
}

struct TeamEventSectionIconBadge: View {
    let systemImage: String
    let tint: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 32, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(colorScheme == .dark ? 0.22 : 0.12))
            )
            .accessibilityHidden(true)
    }
}

// MARK: - WHAT (hero)

struct TeamEventWhatIdentityCard: View {
    let game: PickupGameRow
    let team: PickupGameTeamCreationContext?
    let sportLabel: String
    let languageCode: String
    let showStarted: Bool
    let onShowOnMap: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color {
        if let hex = team?.colorHex, let c = Color(fanTeamHex: hex) { return c }
        return FGColor.intentTeams
    }

    private var mainInk: Color { FGColor.primaryText(colorScheme) }
    private var subInk: Color { FGColor.secondaryText(colorScheme) }

    private var eventTitle: String {
        let title = game.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        return team?.teamName ?? ""
    }

    private var contextLine: String? {
        let type = FanTeamEventPresentation.policy(for: game.gameFormat)
            .localizedTitle(languageCode: languageCode)
        let teamName = team?.teamName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (teamName.isEmpty, type.isEmpty) {
        case (false, false):
            return "\(teamName) · \(type)"
        case (false, true):
            return teamName
        case (true, false):
            return type
        case (true, true):
            return nil
        }
    }

    private var sportToken: String {
        let eventSport = game.sport.trimmingCharacters(in: .whitespacesAndNewlines)
        if !eventSport.isEmpty { return eventSport }
        return team?.teamSport ?? game.sport
    }

    var body: some View {
        TeamEventPlayerCardChrome(tint: accent.opacity(0.55)) {
            Button(action: onShowOnMap) {
                HStack(alignment: .top, spacing: FGSpacing.md) {
                    mark

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

                        if let contextLine {
                            Text(contextLine)
                                .font(FGTypography.metadata.weight(.semibold))
                                .foregroundStyle(accent)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        HStack(spacing: 6) {
                            Image(systemName: SportFilterCatalog.resolve(sportToken).systemImage)
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
            .accessibilityLabel(whatAccessibilityLabel)
        }
    }

    @ViewBuilder
    private var mark: some View {
        if let team {
            FanTeamMarkView(
                sport: team.teamSport,
                logoURL: team.logoURL,
                logoThumbnailURL: team.logoThumbnailURL,
                colorHex: team.colorHex,
                size: 72,
                preferDetailURL: false
            )
            .accessibilityHidden(true)
        } else {
            SportArtworkIconView(sport: sportToken, diameter: 72)
                .accessibilityHidden(true)
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
            .accessibilityLabel(L10n.t("team_event_status_started", languageCode: languageCode))
    }

    private var whatAccessibilityLabel: String {
        let type = FanTeamEventPresentation.policy(for: game.gameFormat)
            .localizedTitle(languageCode: languageCode)
        let privacy = game.is_visible
            ? L10n.t("pickup_form_visibility_public", languageCode: languageCode)
            : L10n.t("pickup_form_visibility_private", languageCode: languageCode)
        var parts = [type, privacy, eventTitle]
        if let contextLine { parts.append(contextLine) }
        parts.append(sportLabel)
        if showStarted {
            parts.append(L10n.t("team_event_status_started", languageCode: languageCode))
        }
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
    }
}

// MARK: - WHEN + WHERE summary

struct TeamEventWhenWhereSummaryCard: View {
    let game: PickupGameRow
    let primary: String?
    let secondary: String?
    let languageCode: String
    let accent: Color
    let canOpenDirections: Bool
    var directionsAccent: Color = FGColor.intentTeams
    let onDirections: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var mainInk: Color { FGColor.primaryText(colorScheme) }
    private var subInk: Color { FGColor.secondaryText(colorScheme) }

    private var dateText: String {
        TeamEventPlayerDetailPresentation.weekdayDateText(for: game, languageCode: languageCode)
    }

    private var timeRange: String? {
        TeamEventPlayerDetailPresentation.timeRangeText(for: game, languageCode: languageCode)
    }

    private var duration: String? {
        game.pickupCompactDurationLabel(languageCode: languageCode)
    }

    private var hasWhen: Bool {
        !dateText.isEmpty || !(timeRange ?? "").isEmpty
    }

    private var hasWhere: Bool { primary != nil }

    var body: some View {
        if hasWhen || hasWhere {
            TeamEventPlayerCardChrome {
                ViewThatFits(in: .horizontal) {
                    wideLayout
                    stackedLayout
                }
            }
            .accessibilityElement(children: .contain)
        } else {
            EmptyView()
        }
    }

    private var wideLayout: some View {
        HStack(alignment: .top, spacing: 0) {
            if hasWhen {
                whenColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if hasWhen && hasWhere {
                columnDivider
            }
            if hasWhere {
                whereColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if canOpenDirections, hasWhere {
                columnDivider
                directionsColumn
            }
        }
    }

    private var stackedLayout: some View {
        VStack(alignment: .leading, spacing: FGSpacing.md) {
            if hasWhen {
                whenColumn
            }
            if hasWhen && hasWhere {
                Rectangle()
                    .fill(FGColor.divider(colorScheme))
                    .frame(height: 1)
                    .accessibilityHidden(true)
            }
            if hasWhere {
                HStack(alignment: .top, spacing: FGSpacing.md) {
                    whereColumn
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if canOpenDirections {
                        directionsColumn
                    }
                }
            }
        }
    }

    private var whenColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            TeamEventSectionIconBadge(systemImage: "calendar", tint: accent)
            if !dateText.isEmpty {
                Text(dateText)
                    .font(FGTypography.metadata.weight(.semibold))
                    .foregroundStyle(mainInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let timeRange, !timeRange.isEmpty {
                Text(timeRange)
                    .font(FGTypography.caption.weight(.medium))
                    .foregroundStyle(subInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let duration, !duration.isEmpty {
                Text("(\(duration))")
                    .font(FGTypography.caption.weight(.medium))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            game.pickupDateTimeDurationAccessibilityLabel(languageCode: languageCode)
                ?? [dateText, timeRange, duration].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        )
    }

    private var whereColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            TeamEventSectionIconBadge(systemImage: "mappin.and.ellipse", tint: FGColor.accentBlue)
            if let primary {
                Text(primary)
                    .font(FGTypography.metadata.weight(.semibold))
                    .foregroundStyle(mainInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let secondary, !secondary.isEmpty {
                Text(secondary)
                    .font(FGTypography.caption.weight(.medium))
                    .foregroundStyle(subInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [primary, secondary].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        )
    }

    private var directionsColumn: some View {
        Button(action: onDirections) {
            VStack(spacing: 6) {
                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.system(size: 18, weight: .semibold))
                Text(L10n.t("Directions", languageCode: languageCode))
                    .font(FGTypography.caption.weight(.bold))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(directionsAccent)
            .frame(minWidth: 72)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            String(
                format: L10n.t("team_event_directions_a11y_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                primary ?? L10n.t("Directions", languageCode: languageCode)
            )
        )
    }

    private var columnDivider: some View {
        Rectangle()
            .fill(FGColor.divider(colorScheme))
            .frame(width: 1)
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .accessibilityHidden(true)
    }
}

// MARK: - YOUR RESPONSE (RSVP)

struct TeamEventYourPlayerCard: View {
    let subject: FanTeamRSVPSubject
    let rsvp: FanTeamGameRSVPStatus?
    let languageCode: String
    let accent: Color
    let isCancelled: Bool
    let isPast: Bool
    let isExcluded: Bool
    let isBusy: Bool
    let onSetGoing: () -> Void
    let onSetCantGo: () -> Void
    let onChangeResponse: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var state: FanTeamScheduleQuickRSVPState {
        FanTeamScheduleQuickRSVPState.from(rsvp: rsvp)
    }

    private var mainInk: Color { FGColor.primaryText(colorScheme) }
    private var subInk: Color { FGColor.secondaryText(colorScheme) }

    private var interactive: Bool {
        !isCancelled && !isPast && !isExcluded
    }

    private var cardTint: Color? {
        guard !isExcluded else { return nil }
        switch state {
        case .going: return statusColor(for: .going)
        case .maybe: return statusColor(for: .maybe)
        case .cantGo: return statusColor(for: .cantGo)
        case .noResponse: return nil
        }
    }

    var body: some View {
        TeamEventPlayerCardChrome(tint: cardTint) {
            Group {
                if isExcluded {
                    excludedBody
                } else if !interactive {
                    readOnlyBody
                } else {
                    switch state {
                    case .noResponse:
                        noResponseBody
                    case .going, .maybe, .cantGo:
                        confirmedBody(state)
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

    private var excludedBody: some View {
        HStack(spacing: FGSpacing.sm) {
            Image(systemName: "person.slash")
                .foregroundStyle(subInk)
            Text(L10n.t("fan_team_schedule_rsvp_not_participating", languageCode: languageCode))
                .font(FGTypography.metadata.weight(.semibold))
                .foregroundStyle(subInk)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var readOnlyBody: some View {
        HStack(spacing: FGSpacing.sm) {
            statusIcon(for: state)
            Text(confirmedTitle(for: state))
                .font(FGTypography.metadata.weight(.semibold))
                .foregroundStyle(statusColor(for: state))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var noResponseBody: some View {
        HStack(alignment: .center, spacing: FGSpacing.md) {
            Text(
                FanTeamScheduleQuickRSVPCopy.prompt(
                    subjectName: subject.promptDisplayName,
                    languageCode: languageCode
                )
            )
            .font(FGTypography.metadata.weight(.semibold))
            .foregroundStyle(mainInk)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Button(action: onSetCantGo) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(FGColor.dangerRed))
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .accessibilityLabel(
                    FanTeamScheduleQuickRSVPCopy.markCantGoA11y(
                        subjectName: subject.promptDisplayName,
                        languageCode: languageCode
                    )
                )

                Button(action: onSetGoing) {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(accent))
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .accessibilityLabel(
                    FanTeamScheduleQuickRSVPCopy.markGoingA11y(
                        subjectName: subject.promptDisplayName,
                        languageCode: languageCode
                    )
                )
            }
        }
    }

    private func confirmedBody(_ state: FanTeamScheduleQuickRSVPState) -> some View {
        Button(action: onChangeResponse) {
            HStack(spacing: FGSpacing.md) {
                statusIcon(for: state)
                VStack(alignment: .leading, spacing: 3) {
                    Text(confirmedTitle(for: state))
                        .font(FGTypography.metadata.weight(.bold))
                        .foregroundStyle(statusColor(for: state))
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
            "\(confirmedTitle(for: state)). \(L10n.t("team_event_change_your_response", languageCode: languageCode))"
        )
    }

    private func confirmedTitle(for state: FanTeamScheduleQuickRSVPState) -> String {
        if subject.isManagedPlayer {
            return FanTeamScheduleQuickRSVPCopy.confirmed(
                state: state,
                subjectName: subject.promptDisplayName,
                languageCode: languageCode
            )
        }
        return TeamEventPlayerDetailPresentation.firstPersonConfirmedTitle(
            state: state,
            languageCode: languageCode
        )
    }

    private func statusIcon(for state: FanTeamScheduleQuickRSVPState) -> some View {
        Image(systemName: {
            switch state {
            case .going: return "checkmark.circle.fill"
            case .maybe: return "questionmark.circle.fill"
            case .cantGo: return "xmark.circle.fill"
            case .noResponse: return "circle"
            }
        }())
        .font(.title2.weight(.semibold))
        .foregroundStyle(statusColor(for: state))
        .accessibilityHidden(true)
    }

    private func statusColor(for state: FanTeamScheduleQuickRSVPState) -> Color {
        switch state {
        case .going: return FGColor.accentGreen
        case .maybe: return FGColor.accentYellow
        case .cantGo: return FGColor.dangerRed
        case .noResponse: return subInk
        }
    }
}

// MARK: - WHO’S GOING

struct TeamEventWhosGoingCard: View {
    let languageCode: String
    let stackMembers: [PickupGameRosterMember]
    let goingCount: Int
    let maybeCount: Int
    let noResponseCount: Int
    let cantGoCount: Int
    let outsideRecruitFooter: AnyView?
    let onViewAll: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var mainInk: Color { FGColor.primaryText(colorScheme) }
    private var subInk: Color { FGColor.secondaryText(colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: FGSpacing.sm) {
            HStack {
                Text(L10n.t("pickup_detail_whos_going", languageCode: languageCode))
                    .font(FGTypography.caption.weight(.bold))
                    .foregroundStyle(subInk)
                    .textCase(.uppercase)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button(action: onViewAll) {
                    Text(L10n.t("View all", languageCode: languageCode))
                        .font(FGTypography.caption.weight(.bold))
                        .foregroundStyle(FGColor.intentTeams)
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
                            attendanceStat(
                                systemImage: "xmark.circle.fill",
                                tint: FGColor.dangerRed,
                                count: cantGoCount,
                                label: L10n.t("fan_team_rsvp_cant_go", languageCode: languageCode)
                            )
                            if noResponseCount > 0 {
                                attendanceStat(
                                    systemImage: "circle.dashed",
                                    tint: FGColor.mutedText(colorScheme),
                                    count: noResponseCount,
                                    label: L10n.t("pickup_detail_no_response", languageCode: languageCode)
                                )
                            }
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityHint(
                L10n.t("pickup_detail_view_team_attendance_a11y_hint", languageCode: languageCode)
            )
            .accessibilityAddTraits(.isButton)

            if let outsideRecruitFooter {
                outsideRecruitFooter
            }
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
        parts.append("\(cantGoCount) \(L10n.t("fan_team_rsvp_cant_go", languageCode: languageCode))")
        if noResponseCount > 0 {
            parts.append("\(noResponseCount) \(L10n.t("pickup_detail_no_response", languageCode: languageCode))")
        }
        return parts.joined(separator: ". ")
    }
}

// MARK: - NOTES (kept for More Details / optional inline use)

struct TeamEventNotesCard: View {
    let description: String?
    let languageCode: String
    let accent: Color

    @Environment(\.colorScheme) private var colorScheme

    private var trimmed: String {
        (description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        if trimmed.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: FGSpacing.sm) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                    Text(L10n.t("team_event_notes_title", languageCode: languageCode))
                        .font(FGTypography.caption.weight(.bold))
                        .foregroundStyle(accent)
                        .textCase(.uppercase)
                }
                .accessibilityAddTraits(.isHeader)

                Text(trimmed)
                    .font(FGTypography.body)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(L10n.t("team_event_notes_title", languageCode: languageCode)). \(trimmed)"
            )
        }
    }
}

// MARK: - MORE DETAILS disclosure

struct TeamEventMoreDetailsSection<Content: View>: View {
    let languageCode: String
    @ViewBuilder var content: () -> Content

    @State private var isExpanded = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content()
                .padding(.top, FGSpacing.sm)
        } label: {
            HStack(spacing: FGSpacing.md) {
                TeamEventSectionIconBadge(
                    systemImage: "doc.text.fill",
                    tint: FGColor.intentTeams
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t("team_event_more_details", languageCode: languageCode))
                        .font(FGTypography.metadata.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text(L10n.t("team_event_more_details_subtitle", languageCode: languageCode))
                        .font(FGTypography.caption.weight(.medium))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .accessibilityAddTraits(.isHeader)
        }
        .padding(FGSpacing.md)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                    .fill(FGColor.cardBackground(colorScheme))
                RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                    .fill(.ultraThinMaterial.opacity(colorScheme == .dark ? 0.55 : 0.35))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                .strokeBorder(
                    FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.55 : 0.45),
                    lineWidth: 1
                )
        }
        .tint(FGColor.secondaryText(colorScheme))
    }
}
