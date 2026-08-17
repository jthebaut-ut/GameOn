import SwiftUI

/// Schedule → Live featured matchup scoreboard: shared professional artwork, 52pt slot.
/// Presentation-only — does not fetch, cache, or call TheSportsDB.
nonisolated enum LiveFeaturedMatchupPresentation {
    static let artworkDiameter: CGFloat = 52
    static let teamNameMaxLines = 2
    static let scoreLayoutPriority: Double = 1
    static let usesSportsIdentityArtworkView = true
    static let usesEqualWidthTeamColumns = true
    static let centersScore = true
    static let preservesWatchNearby = true
    static let preservesFavoriteTeamSelection = true
    static let artworkSource = "LiveFeatured"

    enum Side: Equatable, Sendable {
        case away
        case home
    }

    nonisolated struct TeamArtworkInputs: Equatable, Sendable {
        let teamName: String
        let badgeURL: String?
        let providerId: String?
        let league: String?
        let source: String

        var passesProviderID: Bool {
            let trimmed = providerId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !trimmed.isEmpty
        }

        var passesLeagueContext: Bool {
            let trimmed = league?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !trimmed.isEmpty
        }
    }

    nonisolated struct Model: Equatable, Sendable {
        let away: TeamArtworkInputs
        let home: TeamArtworkInputs
        let awayScore: Int?
        let homeScore: Int?
        let scoresAvailable: Bool
        let isLive: Bool
        let isFinal: Bool
        let showsWatchNearby: Bool
        let leagueLine: String
    }

    static func leagueContext(for match: LiveMatch) -> String {
        let named = match.sourceLeagueName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !named.isEmpty { return named }
        return match.league.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func artworkInputs(from match: LiveMatch, side: Side) -> TeamArtworkInputs {
        let league = leagueContext(for: match)
        let source = match.source?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch side {
        case .away:
            return TeamArtworkInputs(
                teamName: match.awayTeam,
                badgeURL: match.awayTeamBadgeURL,
                providerId: match.awayTeamProviderId,
                league: league,
                source: (source?.isEmpty == false ? source : nil) ?? artworkSource
            )
        case .home:
            return TeamArtworkInputs(
                teamName: match.homeTeam,
                badgeURL: match.homeTeamBadgeURL,
                providerId: match.homeTeamProviderId,
                league: league,
                source: (source?.isEmpty == false ? source : nil) ?? artworkSource
            )
        }
    }

    static func model(
        from match: LiveMatch,
        showsWatchNearby: Bool
    ) -> Model {
        let scoresAvailable = match.scoresAreAvailable
            && (match.matchStatus.isHappeningNow || match.matchStatus == .fullTime)
        return Model(
            away: artworkInputs(from: match, side: .away),
            home: artworkInputs(from: match, side: .home),
            awayScore: scoresAvailable ? match.scoreAway : nil,
            homeScore: scoresAvailable ? match.scoreHome : nil,
            scoresAvailable: scoresAvailable,
            isLive: match.matchStatus.isHappeningNow,
            isFinal: match.matchStatus == .fullTime,
            showsWatchNearby: showsWatchNearby,
            leagueLine: leagueContext(for: match)
        )
    }

    static func resolveArtwork(_ inputs: TeamArtworkInputs) -> SportsIdentityArtworkDescriptor {
        SportsIdentityArtworkResolver.resolveProGameTeam(
            teamName: inputs.teamName,
            badgeURL: inputs.badgeURL,
            entityID: inputs.providerId,
            league: inputs.league,
            source: inputs.source,
            diameter: artworkDiameter
        )
    }

    static func isVerifiedRemote(_ descriptor: SportsIdentityArtworkDescriptor) -> Bool {
        if case .verifiedRemote = descriptor.kind { return true }
        return false
    }

    static func isMissingOfficialLogo(_ descriptor: SportsIdentityArtworkDescriptor) -> Bool {
        !isVerifiedRemote(descriptor)
    }
}

struct LiveFeaturedMatchupScoreboard: View {
    let awayName: String
    let homeName: String
    let awayScore: Int?
    let homeScore: Int?
    let scoresAvailable: Bool
    let awayBadgeURL: String?
    let homeBadgeURL: String?
    let awayProviderId: String?
    let homeProviderId: String?
    let league: String?
    let source: String
    let isLive: Bool
    let isFinal: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            teamColumn(
                name: awayName,
                badgeURL: awayBadgeURL,
                providerId: awayProviderId
            )
            .frame(maxWidth: .infinity)

            scoreCluster
                .layoutPriority(LiveFeaturedMatchupPresentation.scoreLayoutPriority)
                .fixedSize(horizontal: true, vertical: false)

            teamColumn(
                name: homeName,
                badgeURL: homeBadgeURL,
                providerId: homeProviderId
            )
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, isFinal ? 12 : 0)
        .padding(.vertical, isFinal ? 10 : 2)
        .background {
            if isFinal {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.gray.opacity(colorScheme == .dark ? 0.20 : 0.10))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var scoreCluster: some View {
        Group {
            if scoresAvailable, let awayScore, let homeScore {
                Text("\(awayScore) – \(homeScore)")
                    .font(.system(size: 22, weight: .black, design: .rounded).monospacedDigit())
                    .foregroundStyle(isLive && !isFinal ? FGColor.dangerRed : FGColor.primaryText(colorScheme))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            } else {
                Text("vs")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
        }
    }

    private func teamColumn(name: String, badgeURL: String?, providerId: String?) -> some View {
        VStack(spacing: 8) {
            SportsIdentityArtworkView(
                teamName: name,
                badgeURL: badgeURL,
                entityID: providerId,
                league: league,
                source: source,
                diameter: LiveFeaturedMatchupPresentation.artworkDiameter,
                plate: .neutralLogo
            )
            Text(ProGameTeamScoreIdentity.cleanTeamName(name))
                .font(.caption.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.center)
                .lineLimit(LiveFeaturedMatchupPresentation.teamNameMaxLines)
                .minimumScaleFactor(0.72)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var accessibilityLabel: String {
        let away = ProGameTeamScoreIdentity.cleanTeamName(awayName)
        let home = ProGameTeamScoreIdentity.cleanTeamName(homeName)
        if scoresAvailable, let awayScore, let homeScore {
            return "\(away) \(awayScore) to \(homeScore) \(home)"
        }
        return "\(away) versus \(home)"
    }
}
