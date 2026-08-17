import SwiftUI

struct GoingProReasonBadge: View {
    enum Kind {
        case saved
        case favoriteTeam
        case live

        var titleKey: String {
            switch self {
            case .saved: return "Saved"
            case .favoriteTeam: return "going_pro_badge_favorite_team"
            case .live: return "LIVE"
            }
        }

        var systemImage: String {
            switch self {
            case .saved: return "bookmark.fill"
            case .favoriteTeam: return "heart.fill"
            case .live: return "dot.radiowaves.left.and.right"
            }
        }
    }

    let kind: Kind
    let languageCode: String
    let colorScheme: ColorScheme

    private var title: String {
        L10n.t(kind.titleKey, languageCode: languageCode)
    }

    private var tint: Color {
        switch kind {
        case .saved: return FGColor.accentBlue
        case .favoriteTeam: return FGColor.accentGreen
        case .live: return FGColor.dangerRed
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 8, weight: .bold))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .tracking(0.2)
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(colorScheme == .dark ? 0.22 : 0.14), in: Capsule(style: .continuous))
        .accessibilityLabel(title)
    }
}

struct GoingProFilterChip: View {
    let filter: GoingProGamesFilter
    let count: Int
    let selected: Bool
    let languageCode: String
    let colorScheme: ColorScheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if filter != .all {
                    Image(systemName: filter.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(L10n.t(filter.titleKey, languageCode: languageCode))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("\(max(0, count))")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(selected ? FGColor.accentBlue : FGColor.secondaryText(colorScheme))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(selected ? FGColor.accentBlue : FGColor.primaryText(colorScheme))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        selected
                            ? FGColor.accentBlue.opacity(colorScheme == .dark ? 0.22 : 0.12)
                            : Color(.systemBackground).opacity(colorScheme == .dark ? 0.55 : 1)
                    )
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        selected
                            ? FGColor.accentBlue.opacity(0.55)
                            : FGColor.divider(colorScheme).opacity(0.85),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(L10n.t(filter.titleKey, languageCode: languageCode)), \(count)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct GoingProFavoriteTeamMark: View {
    let team: FavoriteTeam
    let languageCode: String
    let colorScheme: ColorScheme

    var body: some View {
        VStack(spacing: 6) {
            SportsIdentityArtworkView(
                favoriteTeam: team,
                diameter: SportsIdentityArtworkMetrics.favoriteSlot,
                plate: .system
            )
            Text(team.name)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .multilineTextAlignment(.center)
                .frame(width: 72, alignment: .center)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(team.name), \(L10n.t("going_pro_badge_favorite_team", languageCode: languageCode))"
        )
    }
}

/// Compact body matchup (logos + separator or score) when the full scoreboard is hidden.
/// Not used in the title/header row — that duplicate cluster was removed.
struct GoingProMatchupVisual: View {
    let game: SavedProGame
    let liveMatches: [LiveMatch]
    let isLive: Bool
    let colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: 8) {
            teamMark(name: game.awayTeam)
            if isLive || game.isFinal {
                Text("\(game.scoreAway) – \(game.scoreHome)")
                    .font(.system(size: 15, weight: .black, design: .rounded).monospacedDigit())
                    .foregroundStyle(isLive ? FGColor.dangerRed : FGColor.primaryText(colorScheme))
                    .lineLimit(1)
            } else {
                Text(GoingProGamesProjection.matchupSeparator(for: game.liveSportVisualType))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
            teamMark(name: game.homeTeam)
        }
        .accessibilityHidden(true)
    }

    private func teamMark(name: String) -> some View {
        SportsIdentityArtworkView(
            teamName: name,
            badgeURL: GoingProGameTeamArtwork.badgeURL(for: name, game: game, liveMatches: liveMatches),
            entityID: GoingProGameTeamArtwork.providerId(for: name, game: game, liveMatches: liveMatches),
            league: game.league,
            source: game.source ?? "GoingPro",
            diameter: SportsIdentityArtworkMetrics.matchupSlot
        )
    }
}

enum GoingProGameTeamArtwork {
    static func matchingLiveMatch(for game: SavedProGame, liveMatches: [LiveMatch]) -> LiveMatch? {
        if let exact = liveMatches.first(where: { SavedProGame.stableKey(for: $0) == game.stableKey }) {
            return exact
        }
        let source = game.source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let externalId = game.externalId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !source.isEmpty, !externalId.isEmpty else { return nil }
        return liveMatches.first {
            $0.source?.caseInsensitiveCompare(source) == .orderedSame
                && $0.externalId?.caseInsensitiveCompare(externalId) == .orderedSame
        }
    }

    static func badgeURL(for team: String, game: SavedProGame, liveMatches: [LiveMatch]) -> String? {
        matchingLiveMatch(for: game, liveMatches: liveMatches)?.badgeURL(forTeamName: team)
    }

    static func providerId(for team: String, game: SavedProGame, liveMatches: [LiveMatch]) -> String? {
        guard let match = matchingLiveMatch(for: game, liveMatches: liveMatches) else { return nil }
        let cleaned = ProGameTeamScoreIdentity.cleanTeamName(team)
        let normalized = LiveMatchFilters.normalizedSearchText(cleaned)
        if LiveMatchFilters.normalizedSearchText(match.awayTeam) == normalized {
            return match.awayTeamProviderId
        }
        if LiveMatchFilters.normalizedSearchText(match.homeTeam) == normalized {
            return match.homeTeamProviderId
        }
        return nil
    }
}

enum GoingProLiveScoreboardMetrics {
    static let artworkDiameter: CGFloat = SportsIdentityArtworkMetrics.liveScoreboardSlot
    static let scorePointSize: CGFloat = 40
    static let separatorPointSize: CGFloat = 28
    static let clockPointSize: CGFloat = 16
    static let liveStatusPointSize: CGFloat = 32
    static let teamNameMaxLines = 2
    static let scoreLayoutPriority: Double = 1
    static let cardCornerRadius: CGFloat = 20
    static let cardPadding: CGFloat = 16
}

struct GoingProLiveSportMark: View {
    let sportType: LiveSportVisualType
    var featuredEvent: FeaturedEvent?
    var featuredEventSlug: String?

    var body: some View {
        ZStack(alignment: .top) {
            ProGameSportBadgeView(
                sportType: sportType,
                diameter: 36,
                featuredEvent: featuredEvent,
                featuredEventSlug: featuredEventSlug
            )
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(FGColor.dangerRed)
                .offset(y: -8)
                .accessibilityHidden(true)
        }
        .accessibilityHidden(true)
    }
}

struct GoingProLiveStatusHeadline: View {
    let status: GoingProLiveCardPresentation.PrimaryStatus
    let languageCode: String
    @ScaledMetric(relativeTo: .title) private var liveSize: CGFloat = GoingProLiveScoreboardMetrics.liveStatusPointSize

    var body: some View {
        HStack(spacing: 10) {
            hairline
            statusLabel
            hairline
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .live:
            HStack(spacing: 8) {
                Circle()
                    .fill(FGColor.dangerRed)
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
                Text(L10n.t("LIVE", languageCode: languageCode))
                    .font(.system(size: liveSize, weight: .heavy, design: .rounded))
                    .foregroundStyle(FGColor.dangerRed)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        case .halfTime:
            Text(L10n.t("Halftime", languageCode: languageCode))
                .font(.system(size: liveSize, weight: .heavy, design: .rounded))
                .foregroundStyle(FGColor.dangerRed)
                .textCase(.uppercase)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(FGColor.dangerRed.opacity(0.22))
            .frame(height: 0.8)
            .frame(maxWidth: .infinity)
    }
}

struct GoingProLiveContextChip: View {
    let chip: GoingProLiveCardPresentation.ContextChip
    let languageCode: String
    let colorScheme: ColorScheme
    var action: (() -> Void)? = nil

    var body: some View {
        if let action {
            Button(action: action) {
                chipLabel
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        } else {
            chipLabel
        }
    }

    private var chipLabel: some View {
        HStack(spacing: 4) {
            if let symbol = symbolName {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                    .accessibilityHidden(true)
            } else if let emoji = emoji {
                Text(emoji)
                    .font(.caption2)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.caption2.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(colorScheme == .dark ? 0.20 : 0.12))
        )
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(tint.opacity(colorScheme == .dark ? 0.32 : 0.18), lineWidth: 0.8)
        }
        .accessibilityLabel(title)
    }

    private var title: String {
        switch chip {
        case let .sport(_, label):
            return label
        case .favoriteTeam:
            return L10n.t("going_pro_badge_favorite_team", languageCode: languageCode)
        case .liveAlertsOn:
            return L10n.t("going_pro_live_alerts_on", languageCode: languageCode)
        case .liveAlertsOff:
            return L10n.t("going_pro_live_alerts_off", languageCode: languageCode)
        }
    }

    private var emoji: String? {
        if case let .sport(emoji, _) = chip { return emoji }
        return nil
    }

    private var symbolName: String? {
        switch chip {
        case .sport:
            return nil
        case .favoriteTeam:
            return "heart.fill"
        case .liveAlertsOn:
            return "bell.fill"
        case .liveAlertsOff:
            return "bell.slash"
        }
    }

    private var tint: Color {
        switch chip {
        case .sport:
            return FGColor.secondaryText(colorScheme)
        case .favoriteTeam, .liveAlertsOn:
            return FGColor.accentGreen
        case .liveAlertsOff:
            return FGColor.mutedText(colorScheme)
        }
    }
}

struct GoingProLiveScoreboardView: View {
    let game: SavedProGame
    let liveMatches: [LiveMatch]
    let presentation: GoingProLiveCardPresentation
    let colorScheme: ColorScheme
    @ScaledMetric(relativeTo: .largeTitle) private var scoreSize: CGFloat = GoingProLiveScoreboardMetrics.scorePointSize
    @ScaledMetric(relativeTo: .callout) private var clockSize: CGFloat = GoingProLiveScoreboardMetrics.clockPointSize

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            teamColumn(
                name: presentation.awayTeamName,
                team: game.awayTeam
            )
            .frame(maxWidth: .infinity)

            scoreCluster
                .layoutPriority(GoingProLiveScoreboardMetrics.scoreLayoutPriority)
                .fixedSize(horizontal: true, vertical: false)

            teamColumn(
                name: presentation.homeTeamName,
                team: game.homeTeam
            )
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    private var scoreCluster: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text("\(presentation.awayScore)")
                    .font(.system(size: scoreSize, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(FGColor.dangerRed)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)

                Text("–")
                    .font(.system(size: GoingProLiveScoreboardMetrics.separatorPointSize, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.mutedText(colorScheme).opacity(0.7))

                Text("\(presentation.homeScore)")
                    .font(.system(size: scoreSize, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(FGColor.dangerRed)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }

            if let clock = presentation.clockText, !clock.isEmpty {
                Text(clock)
                    .font(.system(size: clockSize, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private func teamColumn(name: String, team: String) -> some View {
        VStack(spacing: 8) {
            SportsIdentityArtworkView(
                teamName: team,
                badgeURL: GoingProGameTeamArtwork.badgeURL(for: team, game: game, liveMatches: liveMatches),
                entityID: GoingProGameTeamArtwork.providerId(for: team, game: game, liveMatches: liveMatches),
                league: game.league,
                source: game.source ?? "GoingPro",
                diameter: GoingProLiveScoreboardMetrics.artworkDiameter,
                plate: .neutralLogo
            )
            Text(name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.center)
                .lineLimit(GoingProLiveScoreboardMetrics.teamNameMaxLines)
                .minimumScaleFactor(0.72)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}
