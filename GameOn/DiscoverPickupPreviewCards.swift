import SwiftUI

// MARK: - DEBUG crash isolation (Discover selected Pickup preview)

/// DEBUG breadcrumb trail for Discover → selected Pickup preview card render.
/// Process death immediately after `previewCardRender` with no child markers points at
/// SwiftUI opaque-type / stack-guard failure while constructing this tree (same class as
/// `DiscoverMapVenuePreviewCardHost` / `VenuePreviewProHeroGameCard`).
enum PickupPreviewCrashTrace {
    private static let lock = NSLock()
    private static var evaluationCounts: [String: Int] = [:]

    static func log(
        _ stage: String,
        gameId: UUID,
        teamId: UUID? = nil,
        teamName: String? = nil,
        logoURLPresent: Bool? = nil,
        thumbnailURLPresent: Bool? = nil,
        colorHexPresent: Bool? = nil,
        extra: String? = nil
    ) {
#if DEBUG
        lock.lock()
        let count = (evaluationCounts[stage] ?? 0) + 1
        evaluationCounts[stage] = count
        lock.unlock()

        var parts: [String] = [
            "[PickupPreviewCrashTrace]",
            stage,
            "gameId=\(gameId.uuidString.lowercased())",
            "previewEvaluationCount=\(count)"
        ]
        if let teamId {
            parts.append("teamId=\(teamId.uuidString.lowercased())")
        }
        if let teamName {
            let trimmed = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                parts.append("teamName=\(trimmed)")
            }
        }
        if let logoURLPresent {
            parts.append("logoURLPresent=\(logoURLPresent)")
        }
        if let thumbnailURLPresent {
            parts.append("thumbnailURLPresent=\(thumbnailURLPresent)")
        }
        if let colorHexPresent {
            parts.append("colorHexPresent=\(colorHexPresent)")
        }
        if let extra, !extra.isEmpty {
            parts.append(extra)
        }
        print(parts.joined(separator: " "))
#endif
    }

    static func resetCountsForTesting() {
#if DEBUG
        lock.lock()
        evaluationCounts.removeAll(keepingCapacity: false)
        lock.unlock()
#endif
    }
}

#if DEBUG
/// Progressive isolation of Discover Pickup preview children.
/// Default `fullUI` (0) restores the intended card. Override via:
/// `UserDefaults.standard.set(<raw>, forKey: PickupPreviewCrashBisect.userDefaultsKey)`
/// or `PickupPreviewCrashBisect.forcedPhase`.
enum PickupPreviewCrashBisectPhase: Int, CaseIterable {
    case fullUI = 0
    case aTitleOnly = 1
    case bPlusEventBadge = 2
    case cPlusTeamTextOnly = 3
    case dPlusTeamLogo = 4
    case ePlusMetadata = 5
    case fPlusTimeLocation = 6
    case gPlusChips = 7
    case hPlusOrganizer = 8
    case iPlusActions = 9
    case jPlusChrome = 10
}

enum PickupPreviewCrashBisect {
    static let userDefaultsKey = "PickupPreviewCrashBisectPhase"
    static var forcedPhase: PickupPreviewCrashBisectPhase?

    static var activePhase: PickupPreviewCrashBisectPhase {
        if let forcedPhase { return forcedPhase }
        return PickupPreviewCrashBisectPhase(
            rawValue: UserDefaults.standard.integer(forKey: userDefaultsKey)
        ) ?? .fullUI
    }

    static func allows(_ minimum: PickupPreviewCrashBisectPhase) -> Bool {
        let active = activePhase
        if active == .fullUI { return true }
        return active.rawValue >= minimum.rawValue
    }
}
#endif

// MARK: - Shared chrome / chips (concrete; keeps DiscoverScreen opaque types shallow)

struct DiscoverPickupPreviewMetricCapsule: View {
    let text: String
    let mainInk: Color
    let colorScheme: ColorScheme

    var body: some View {
        Text(text)
            .font(FGTypography.caption.weight(.semibold))
            .foregroundStyle(mainInk)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.45))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.22 : 0.38), lineWidth: 0.75)
                    }
            }
    }
}

struct DiscoverPickupPreviewTrailingControl: View {
    let systemImage: String
    let icon: Color
    let colorScheme: ColorScheme

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 38, height: 38)
                .overlay {
                    Circle()
                        .strokeBorder(
                            Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.12),
                            lineWidth: 1
                        )
                }
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(icon)
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
}

struct DiscoverPickupPreviewCardBackground: View {
    let cornerRadius: CGFloat
    let colorScheme: ColorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
            LinearGradient(
                colors: [
                    Color.black.opacity(colorScheme == .dark ? 0.62 : 0.2),
                    Color.black.opacity(colorScheme == .dark ? 0.4 : 0.11)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

/// Team-linked Discover preview glass: shared material + restrained Team wash/border atmosphere.
/// Standalone Pickup continues to use ``DiscoverPickupPreviewCardBackground`` alone.
struct DiscoverTeamLinkedPickupPreviewCardChrome: View {
    let accent: Color
    let cornerRadius: CGFloat
    let colorScheme: ColorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            DiscoverPickupPreviewCardBackground(
                cornerRadius: cornerRadius,
                colorScheme: colorScheme
            )
            // Soft Team atmosphere — perceptible over the map, never a solid color block.
            shape.fill(accent.opacity(FanTeamColorTheme.discoverPreviewWashOpacity(for: colorScheme)))
        }
    }
}

struct DiscoverPrivateTeamPreviewBadge: View {
    let accent: Color
    let languageCode: String
    let colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill")
                .font(.caption2.weight(.semibold))
            Text(L10n.t("fan_teams_private_team", languageCode: languageCode))
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(accent.opacity(colorScheme == .dark ? 0.22 : 0.12), in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(accent.opacity(colorScheme == .dark ? 0.4 : 0.28), lineWidth: 1)
        )
        .accessibilityLabel(L10n.t("fan_teams_private_team", languageCode: languageCode))
    }
}

struct DiscoverPickupPreviewActionRow: View {
    let row: PickupGameRow
    let guestMapsActionsToLogin: Bool
    let detailTitle: String
    let showsDetailsButton: Bool
    let colorScheme: ColorScheme
    let openDetailAction: () -> Void
    let openDirections: (URL) -> Void

    var body: some View {
        HStack(spacing: FGSpacing.sm) {
            if !guestMapsActionsToLogin, let lat = row.latitude, let lon = row.longitude {
                Button {
                    if let url = URL(string: "http://maps.apple.com/?ll=\(lat),\(lon)&q=Pickup%20game") {
                        openDirections(url)
                    }
                } label: {
                    Label("Directions", systemImage: "map")
                        .font(FGTypography.metadata.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(FGColor.accentBlue)
            }

            if showsDetailsButton {
                Button {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
                        openDetailAction()
                    }
                } label: {
                    Text(detailTitle)
                        .font(FGTypography.metadata.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(colorScheme == .dark ? Color.white.opacity(0.92) : FGColor.accentBlue)
            }
        }
    }
}

// MARK: - Team-linked preview (concrete leaf — breaks DiscoverScreen overlay opaque-type explosion)

/// Concrete leaf for Team-linked Discover map selection. Intentionally **non-generic** and
/// owned outside `DiscoverScreen` so bottom-overlay refresh wrappers cannot recursively bake
/// this tree into one explosively nested `ModifiedContent` type (stack-guard death).
struct DiscoverTeamLinkedPickupPreviewCard: View {
    @ObservedObject var viewModel: MapViewModel
    let row: PickupGameRow
    let teamIdentity: PickupDiscoverTeamIdentity
    let languageCode: String
    let cardBorder: Color
    let onOpenDetails: () -> Void
    let onDismiss: () -> Void
    let openDirections: (URL) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var chatViewModel: ChatViewModel

    private let previewCorner: CGFloat = 30

    var body: some View {
        let _ = PickupPreviewCrashTrace.log("preview.begin", gameId: row.id)
        let policy = resolvedPolicy
        let _ = PickupPreviewCrashTrace.log(
            "policy.resolved",
            gameId: row.id,
            teamId: teamIdentity.teamId,
            teamName: teamIdentity.teamName,
            logoURLPresent: !(teamIdentity.logoURL ?? "").isEmpty,
            thumbnailURLPresent: !(teamIdentity.logoThumbnailURL ?? "").isEmpty,
            colorHexPresent: !(teamIdentity.colorHex ?? "").isEmpty,
            extra: "showsPublicAvailability=\(policy.showsPublicAvailability) outsideRecruiting=\(policy.isOutsideRecruiting)"
        )

#if DEBUG
        let phase = PickupPreviewCrashBisect.activePhase
        let _ = PickupPreviewCrashTrace.log(
            "bisect.phase",
            gameId: row.id,
            extra: "phase=\(phase.rawValue)"
        )
#endif

        return cardChrome(policy: policy) {
#if DEBUG
            if !PickupPreviewCrashBisect.allows(.aTitleOnly) {
                EmptyView()
            } else {
                teamLinkedContent(policy: policy)
            }
#else
            teamLinkedContent(policy: policy)
#endif
        }
    }

    private struct ResolvedPolicy {
        let locationLine: String
        let metadataLine: String
        let mainInk: Color
        let subInk: Color
        let dismissIcon: Color
        let showsPublicAvailability: Bool
        let teamAccent: Color
        let detailTitle: String
        let showStarted: Bool
        let titleDistinctFromTeam: Bool
        let teamIdentityLabel: String
        let isOutsideRecruiting: Bool
    }

    private var resolvedPolicy: ResolvedPolicy {
        let locationLine = [row.address, row.city, row.state]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let metadataLine =
            "\(row.sportIdentityLabel()) • \(row.skillLevelEnum.displayTitle) • \(row.playEnvironmentEnum.shortLabel)"
        let mainInk = colorScheme == .dark ? Color.white.opacity(0.92) : FGColor.primaryText(colorScheme)
        let subInk = colorScheme == .dark ? Color.white.opacity(0.72) : FGColor.secondaryText(colorScheme)
        let dismissIcon = colorScheme == .dark ? Color.white.opacity(0.72) : Color.secondary
        let showsPublicAvailability = PickupDiscoverTeamPresentation.shouldShowPublicAvailability(
            identity: teamIdentity,
            game: row
        )
        // One Team preview accent: valid custom Team color (contrast-adjusted) or FanGeo Play orange.
        let teamAccent = FanTeamColorTheme.pickupDiscoverPreviewAccent(
            colorHex: teamIdentity.colorHex,
            colorScheme: colorScheme
        )
        let isOutsideRecruiting = PickupDiscoverTeamPresentation.isOutsideRecruiting(for: row)
        let detailTitle = L10n.t(
            PickupDiscoverTeamPresentation.previewPrimaryCTATitleKey(
                isTeamLinked: true,
                isOutsideRecruiting: isOutsideRecruiting
            ),
            languageCode: languageCode
        )
        let teamIdentityLabel = String(
            format: L10n.t("pickup_preview_team_identity_format", languageCode: languageCode),
            locale: Locale(identifier: L10n.normalizedLanguageCode(languageCode)),
            teamIdentity.teamName
        )
        return ResolvedPolicy(
            locationLine: locationLine,
            metadataLine: metadataLine,
            mainInk: mainInk,
            subInk: subInk,
            dismissIcon: dismissIcon,
            showsPublicAvailability: showsPublicAvailability,
            teamAccent: teamAccent,
            detailTitle: detailTitle,
            showStarted: row.hasPickupGameStarted(),
            titleDistinctFromTeam: row.title.caseInsensitiveCompare(teamIdentity.teamName) != .orderedSame,
            teamIdentityLabel: teamIdentityLabel,
            isOutsideRecruiting: isOutsideRecruiting
        )
    }

    @ViewBuilder
    private func teamLinkedContent(policy: ResolvedPolicy) -> some View {
        VStack(alignment: .leading, spacing: FGSpacing.lg) {
            HStack(alignment: .top, spacing: FGSpacing.md) {
                // Sibling interaction surface (not a parent Button wrapping action Buttons).
                VStack(alignment: .leading, spacing: 12) {
#if DEBUG
                    if PickupPreviewCrashBisect.allows(.bPlusEventBadge) {
                        badgesRow(policy: policy)
                    }
                    if PickupPreviewCrashBisect.allows(.cPlusTeamTextOnly) {
                        teamIdentityRow(policy: policy, includeLogo: PickupPreviewCrashBisect.allows(.dPlusTeamLogo))
                    }
                    if PickupPreviewCrashBisect.allows(.aTitleOnly) {
                        titleBlock(policy: policy)
                    }
                    if PickupPreviewCrashBisect.allows(.ePlusMetadata) {
                        metadataBlock(policy: policy)
                    }
                    if PickupPreviewCrashBisect.allows(.fPlusTimeLocation) {
                        timeBlock(policy: policy)
                        locationBlock(policy: policy)
                    }
                    if PickupPreviewCrashBisect.allows(.gPlusChips) {
                        chipsBlock(policy: policy)
                    }
#else
                    badgesRow(policy: policy)
                    teamIdentityRow(policy: policy, includeLogo: true)
                    titleBlock(policy: policy)
                    metadataBlock(policy: policy)
                    timeBlock(policy: policy)
                    locationBlock(policy: policy)
                    chipsBlock(policy: policy)
#endif
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
                        onOpenDetails()
                    }
                }
                .accessibilityAddTraits(.isButton)

                trailingControls(policy: policy)
            }

#if DEBUG
            if PickupPreviewCrashBisect.allows(.hPlusOrganizer) {
                organizerBlock()
            }
            if PickupPreviewCrashBisect.allows(.iPlusActions) {
                actionsBlock(policy: policy)
            }
#else
            organizerBlock()
            actionsBlock(policy: policy)
#endif
        }
        .padding(FGSpacing.lg)
    }

    @ViewBuilder
    private func cardChrome<Content: View>(
        policy: ResolvedPolicy,
        @ViewBuilder content: () -> Content
    ) -> some View {
#if DEBUG
        let applyChrome = PickupPreviewCrashBisect.allows(.jPlusChrome)
#else
        let applyChrome = true
#endif
        let _ = PickupPreviewCrashTrace.log("background.begin", gameId: row.id)
        Group {
            if applyChrome {
                content()
                    .background {
                        DiscoverTeamLinkedPickupPreviewCardChrome(
                            accent: policy.teamAccent,
                            cornerRadius: previewCorner,
                            colorScheme: colorScheme
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: previewCorner, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: previewCorner, style: .continuous)
                            .strokeBorder(
                                policy.teamAccent.opacity(
                                    FanTeamColorTheme.discoverPreviewStrokeOpacity(for: colorScheme)
                                ),
                                lineWidth: 1.25
                            )
                    }
                    .shadow(
                        color: Color.black.opacity(colorScheme == .dark ? 0.42 : 0.16),
                        radius: colorScheme == .dark ? 28 : 18,
                        x: 0,
                        y: colorScheme == .dark ? 16 : 10
                    )
                    .shadow(
                        color: policy.teamAccent.opacity(
                            FanTeamColorTheme.discoverPreviewGlowOpacity(for: colorScheme)
                        ),
                        radius: 16,
                        x: 0,
                        y: 4
                    )
            } else {
                content()
            }
        }
        .task(id: row.id) {
            await loadOrganizer()
        }
        .onAppear {
            PickupGameStartedStateDebug.log(
                row: row,
                now: Date(),
                allowedActions: "discover_map_preview"
            )
            let _ = PickupPreviewCrashTrace.log("accessibility.begin", gameId: row.id)
            let _ = PickupPreviewCrashTrace.log("accessibility.end", gameId: row.id)
            let _ = PickupPreviewCrashTrace.log("background.end", gameId: row.id)
            let _ = PickupPreviewCrashTrace.log("preview.end", gameId: row.id)
        }
    }

    private func badgesRow(policy: ResolvedPolicy) -> some View {
        HStack(spacing: 8) {
            // Team-linked only: format badge shares the same Team accent as Private Team.
            GameFormatBadgeView(
                format: row.gameFormat,
                colorScheme: colorScheme,
                accent: policy.teamAccent
            )
            if !row.is_visible {
                DiscoverPrivateTeamPreviewBadge(
                    accent: policy.teamAccent,
                    languageCode: languageCode,
                    colorScheme: colorScheme
                )
            }
        }
    }

    @ViewBuilder
    private func teamIdentityRow(policy: ResolvedPolicy, includeLogo: Bool) -> some View {
        let _ = PickupPreviewCrashTrace.log(
            "teamIdentity.begin",
            gameId: row.id,
            teamId: teamIdentity.teamId,
            teamName: teamIdentity.teamName,
            logoURLPresent: !(teamIdentity.logoURL ?? "").isEmpty,
            thumbnailURLPresent: !(teamIdentity.logoThumbnailURL ?? "").isEmpty,
            colorHexPresent: !(teamIdentity.colorHex ?? "").isEmpty,
            extra: "includeLogo=\(includeLogo)"
        )
        HStack(spacing: 12) {
            if includeLogo {
                let _ = PickupPreviewCrashTrace.log(
                    "teamIdentity.logo.begin",
                    gameId: row.id,
                    teamId: teamIdentity.teamId,
                    logoURLPresent: !(teamIdentity.logoURL ?? "").isEmpty,
                    thumbnailURLPresent: !(teamIdentity.logoThumbnailURL ?? "").isEmpty
                )
                FanTeamMarkView(
                    sport: teamIdentity.teamSport.isEmpty ? row.sport : teamIdentity.teamSport,
                    logoURL: teamIdentity.logoURL,
                    logoThumbnailURL: teamIdentity.logoThumbnailURL,
                    colorHex: teamIdentity.colorHex,
                    size: 40,
                    preferDetailURL: false,
                    displayRefreshToken: teamIdentity.displayRefreshToken
                )
                .shadow(color: policy.teamAccent.opacity(0.28), radius: 8, y: 3)
                .accessibilityHidden(true)
                let _ = PickupPreviewCrashTrace.log(
                    "teamIdentity.logo.end",
                    gameId: row.id,
                    teamId: teamIdentity.teamId
                )
            }

            let _ = PickupPreviewCrashTrace.log(
                "teamIdentity.text.begin",
                gameId: row.id,
                teamId: teamIdentity.teamId,
                teamName: teamIdentity.teamName
            )
            Text(policy.teamIdentityLabel)
                .font(FGTypography.sectionTitle.weight(.bold))
                .foregroundStyle(policy.mainInk)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .multilineTextAlignment(.leading)
                .shadow(
                    color: policy.teamAccent.opacity(colorScheme == .dark ? 0.35 : 0.18),
                    radius: 0,
                    y: 0
                )
            let _ = PickupPreviewCrashTrace.log(
                "teamIdentity.text.end",
                gameId: row.id,
                teamId: teamIdentity.teamId
            )
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 2)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(policy.teamAccent.opacity(colorScheme == .dark ? 0.14 : 0.08))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(policy.teamIdentityLabel)
        .onAppear {
            PickupPreviewCrashTrace.log(
                "teamIdentity.end",
                gameId: row.id,
                teamId: teamIdentity.teamId,
                teamName: teamIdentity.teamName
            )
        }
    }

    @ViewBuilder
    private func titleBlock(policy: ResolvedPolicy) -> some View {
        let _ = PickupPreviewCrashTrace.log("title.begin", gameId: row.id)
        if policy.titleDistinctFromTeam {
            Text(row.title)
                .font(FGTypography.metadata.weight(.semibold))
                .foregroundStyle(policy.subInk)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        let _ = PickupPreviewCrashTrace.log("title.end", gameId: row.id)
    }

    private func metadataBlock(policy: ResolvedPolicy) -> some View {
        let _ = PickupPreviewCrashTrace.log("metadata.begin", gameId: row.id)
        return Text(policy.metadataLine)
            .font(FGTypography.metadata.weight(.medium))
            .foregroundStyle(policy.subInk)
            .lineLimit(2)
            .minimumScaleFactor(0.88)
            .onAppear {
                PickupPreviewCrashTrace.log("metadata.end", gameId: row.id)
            }
    }

    @ViewBuilder
    private func timeBlock(policy: ResolvedPolicy) -> some View {
        let _ = PickupPreviewCrashTrace.log("time.begin", gameId: row.id)
        if let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) {
            let visible = row.pickupDateWithCompactTimeRangeAndDuration(languageCode: languageCode)
                ?? start.formatted(
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
            let a11y = row.pickupDateTimeDurationAccessibilityLabel(languageCode: languageCode) ?? visible
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "clock.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(policy.teamAccent.opacity(0.85))
                Text(visible)
                    .font(FGTypography.metadata.weight(.semibold))
                    .foregroundStyle(policy.mainInk)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(a11y)
            }
            if policy.showStarted {
                PickupGameStartedLineCaption()
                    .padding(.top, 2)
            }
        }
        let _ = PickupPreviewCrashTrace.log("time.end", gameId: row.id)
    }

    @ViewBuilder
    private func locationBlock(policy: ResolvedPolicy) -> some View {
        let _ = PickupPreviewCrashTrace.log("location.begin", gameId: row.id)
        if !policy.locationLine.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FGColor.accentBlue)
                Text(policy.locationLine)
                    .font(FGTypography.caption)
                    .foregroundStyle(policy.subInk)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        let _ = PickupPreviewCrashTrace.log("location.end", gameId: row.id)
    }

    @ViewBuilder
    private func chipsBlock(policy: ResolvedPolicy) -> some View {
        let _ = PickupPreviewCrashTrace.log("chips.begin", gameId: row.id)
        // Duration lives on the date/time line — do not duplicate as a separate chip.
        let playersNeeded = max(0, row.playersNeededClamped - row.approvedJoinCount)
        if policy.showsPublicAvailability {
            HStack(spacing: FGSpacing.sm) {
                DiscoverPickupPreviewMetricCapsule(
                    text: pickupLocalizedSpotsLeft(playersNeeded, languageCode: languageCode),
                    mainInk: policy.mainInk,
                    colorScheme: colorScheme
                )
            }
        }
        let _ = PickupPreviewCrashTrace.log("chips.end", gameId: row.id)
    }

    private func organizerBlock() -> some View {
        let _ = PickupPreviewCrashTrace.log("organizer.begin", gameId: row.id)
        return PickupOrganizerPreviewIdentityRow(
            viewModel: viewModel,
            organizerUserId: row.creator_user_id,
            colorScheme: colorScheme,
            style: .secondaryUnderTeam
        )
        .onAppear {
            PickupPreviewCrashTrace.log("organizer.avatar.begin", gameId: row.id)
            PickupPreviewCrashTrace.log("organizer.avatar.end", gameId: row.id)
            PickupPreviewCrashTrace.log("organizer.text.begin", gameId: row.id)
            PickupPreviewCrashTrace.log("organizer.text.end", gameId: row.id)
            PickupPreviewCrashTrace.log("organizer.end", gameId: row.id)
        }
    }

    private func actionsBlock(policy: ResolvedPolicy) -> some View {
        let _ = PickupPreviewCrashTrace.log("actions.begin", gameId: row.id)
        return DiscoverPickupPreviewActionRow(
            row: row,
            guestMapsActionsToLogin: false,
            detailTitle: policy.detailTitle,
            showsDetailsButton: viewModel.discoverMapContentMode == .pickupGames,
            colorScheme: colorScheme,
            openDetailAction: onOpenDetails,
            openDirections: { url in
                PickupPreviewCrashTrace.log("actions.directions", gameId: row.id)
                openDirections(url)
            }
        )
        .onAppear {
            PickupPreviewCrashTrace.log("actions.details", gameId: row.id)
            PickupPreviewCrashTrace.log("actions.end", gameId: row.id)
        }
    }

    private func trailingControls(policy: ResolvedPolicy) -> some View {
        HStack(spacing: 6) {
            if row.isEligibleForInAppShare() {
                PickupGameShareActionButton(game: row, mapViewModel: viewModel) {
                    DiscoverPickupPreviewTrailingControl(
                        systemImage: "square.and.arrow.up",
                        icon: policy.dismissIcon,
                        colorScheme: colorScheme
                    )
                }
                .environmentObject(chatViewModel)
                .fixedSize()
            }

            Button {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                    onDismiss()
                }
            } label: {
                DiscoverPickupPreviewTrailingControl(
                    systemImage: "xmark",
                    icon: policy.dismissIcon,
                    colorScheme: colorScheme
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss pickup preview")
        }
    }

    private func loadOrganizer() async {
        PickupOrganizerTrustDebug.lifecycle("selected pickup card opened")
        await viewModel.loadPickupCreatorProfilesIfNeeded(creatorUserIds: [row.creator_user_id])
        if viewModel.pickupOrganizerSummary(for: row.creator_user_id) != nil {
            PickupOrganizerTrustDebug.lifecycle("organizer statistics served from cache")
        } else {
            PickupOrganizerTrustDebug.lifecycle("organizer statistics found in existing payload", details: "none")
        }
        await viewModel.refreshPickupOrganizerSummaries(userIds: [row.creator_user_id])
    }
}

// MARK: - Standalone preview (concrete leaf)

struct DiscoverStandalonePickupPreviewCard: View {
    @ObservedObject var viewModel: MapViewModel
    let row: PickupGameRow
    let guestMapsActionsToLogin: Bool
    let languageCode: String
    let cardBorder: Color
    let onOpenDetails: () -> Void
    let onDismiss: () -> Void
    let openDirections: (URL) -> Void
    let presentGuestAuth: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @ScaledMetric(relativeTo: .title2) private var emblemSize: CGFloat = 76

    private let previewCorner: CGFloat = 30

    var body: some View {
        let _ = PickupPreviewCrashTrace.log(
            "preview.begin",
            gameId: row.id,
            extra: "variant=standalone guest=\(guestMapsActionsToLogin)"
        )
        let _ = cardBorder
        let locationLine: String = {
            guard !guestMapsActionsToLogin else { return "" }
            return [row.address, row.city, row.state]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        }()
        let detailSubtitle: String = {
            if guestMapsActionsToLogin {
                return "Sign in to see schedule, location, and roster details"
            }
            return "\(row.sportIdentityLabel()) • \(row.gameFormat.displayTitle(languageCode: languageCode)) • \(row.playEnvironmentEnum.shortLabel)"
        }()
        let mainInk = colorScheme == .dark ? Color.white.opacity(0.92) : FGColor.primaryText(colorScheme)
        let subInk = colorScheme == .dark ? Color.white.opacity(0.72) : FGColor.secondaryText(colorScheme)
        let dismissIcon = colorScheme == .dark ? Color.white.opacity(0.72) : Color.secondary
        let pickupOrange = FGColor.intentPlay
        let detailTitle: String = {
            if guestMapsActionsToLogin {
                return L10n.t("pickup_preview_login_signup", languageCode: languageCode)
            }
            return L10n.t("pickup_preview_details_and_join", languageCode: languageCode)
        }()
        let openDetailAction = {
            if guestMapsActionsToLogin {
                presentGuestAuth()
            } else {
                onOpenDetails()
            }
        }
        let emblemStatus = guestMapsActionsToLogin ? nil : FanGeoPickupEmblemStatus.resolve(row: row)

        return ZStack(alignment: .bottomTrailing) {
            FanGeoPickupEmblemWatermark(
                sport: row.sport,
                subtype: row.sport_subtype,
                size: 156
            )
            .offset(x: 28, y: 18)

            VStack(alignment: .leading, spacing: FGSpacing.md) {
                HStack(alignment: .top, spacing: FGSpacing.md) {
                    FanGeoPickupEmblem(
                        sport: row.sport,
                        subtype: row.sport_subtype,
                        size: emblemSize,
                        status: emblemStatus,
                        languageCode: languageCode
                    )

                    VStack(alignment: .leading, spacing: 7) {
                        FanGeoPickupGameFormatPill(languageCode: languageCode)
                        Text(guestMapsActionsToLogin ? row.sportIdentityLabel() : row.title)
                            .font(FGTypography.sectionTitle)
                            .foregroundStyle(mainInk)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(detailSubtitle)
                            .font(FGTypography.metadata.weight(.medium))
                            .foregroundStyle(subInk)
                            .lineLimit(2)
                            .minimumScaleFactor(0.88)

                        if !guestMapsActionsToLogin, let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) {
                            let visible = row.pickupDateWithCompactTimeRangeAndDuration(languageCode: languageCode)
                                ?? start.formatted(
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
                            let a11y = row.pickupDateTimeDurationAccessibilityLabel(languageCode: languageCode) ?? visible
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "clock.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(pickupOrange)
                                Text(visible)
                                    .font(FGTypography.metadata.weight(.semibold))
                                    .foregroundStyle(mainInk)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.82)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityLabel(a11y)
                            }
                        }

                        if !guestMapsActionsToLogin {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "person.2.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(pickupOrange)
                                Text(row.participantAudienceDisplayTitle)
                                    .font(FGTypography.caption.weight(.medium))
                                    .foregroundStyle(subInk)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if !locationLine.isEmpty {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(pickupOrange)
                                Text(locationLine)
                                    .font(FGTypography.caption)
                                    .foregroundStyle(subInk)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if !guestMapsActionsToLogin {
                            let playersNeeded = max(0, row.playersNeededClamped - row.approvedJoinCount)
                            FanGeoPickupSpotsPill(
                                text: pickupLocalizedSpotsLeft(playersNeeded, languageCode: languageCode)
                            )
                            .padding(.top, 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
                            openDetailAction()
                        }
                    }
                    .accessibilityAddTraits(.isButton)

                    HStack(spacing: 6) {
                        if !guestMapsActionsToLogin, row.isEligibleForInAppShare() {
                            PickupGameShareActionButton(game: row, mapViewModel: viewModel) {
                                DiscoverPickupPreviewTrailingControl(
                                    systemImage: "square.and.arrow.up",
                                    icon: dismissIcon,
                                    colorScheme: colorScheme
                                )
                            }
                            .environmentObject(chatViewModel)
                            .fixedSize()
                        }

                        Button {
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                                onDismiss()
                            }
                        } label: {
                            DiscoverPickupPreviewTrailingControl(
                                systemImage: "xmark",
                                icon: dismissIcon,
                                colorScheme: colorScheme
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss pickup preview")
                    }
                }

                if !guestMapsActionsToLogin {
                    PickupOrganizerPreviewIdentityRow(
                        viewModel: viewModel,
                        organizerUserId: row.creator_user_id,
                        colorScheme: colorScheme
                    )
                }

                FanGeoPickupPreviewActionRow(
                    row: row,
                    guestMapsActionsToLogin: guestMapsActionsToLogin,
                    detailTitle: detailTitle,
                    showsDetailsButton: viewModel.discoverMapContentMode == .pickupGames,
                    colorScheme: colorScheme,
                    openDetailAction: openDetailAction,
                    openDirections: openDirections
                )
            }
        }
        .padding(FGSpacing.lg)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: previewCorner, style: .continuous)
                    .fill(colorScheme == .dark ? Color(red: 0.12, green: 0.10, blue: 0.08) : Color.white)
                LinearGradient(
                    colors: [
                        FGColor.intentPlay.opacity(colorScheme == .dark ? 0.18 : 0.10),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: previewCorner, style: .continuous))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: previewCorner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: previewCorner, style: .continuous)
                .strokeBorder(FGColor.intentPlay.opacity(colorScheme == .dark ? 0.32 : 0.18), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.42 : 0.14), radius: colorScheme == .dark ? 28 : 18, x: 0, y: colorScheme == .dark ? 16 : 10)
        .shadow(color: FGColor.intentPlay.opacity(colorScheme == .dark ? 0.16 : 0.10), radius: 14, x: 0, y: 4)
        .task(id: row.id) {
            guard !guestMapsActionsToLogin else { return }
            PickupOrganizerTrustDebug.lifecycle("selected pickup card opened")
            await viewModel.loadPickupCreatorProfilesIfNeeded(creatorUserIds: [row.creator_user_id])
            await viewModel.refreshPickupOrganizerSummaries(userIds: [row.creator_user_id])
        }
        .onAppear {
            guard !guestMapsActionsToLogin else {
                PickupPreviewCrashTrace.log("preview.end", gameId: row.id, extra: "variant=standalone")
                return
            }
            PickupGameStartedStateDebug.log(
                row: row,
                now: Date(),
                allowedActions: "discover_map_preview"
            )
            PickupPreviewCrashTrace.log("preview.end", gameId: row.id, extra: "variant=standalone")
        }
    }
}
