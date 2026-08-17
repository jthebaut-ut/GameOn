import SwiftUI

/// Size / typography tokens for the shared rich Favorite Team card.
enum FavoriteTeamRichCardStyle: Equatable {
    /// Own Account → Favorite Teams carousel (source of truth dimensions).
    case ownProfile
    /// Public profile Teams I Follow — compact, still premium.
    case publicCompact

    /// Team-color gradient backgrounds are retired. Cards use a light/neutral surface.
    static let usesTeamColorGradient = false

    var width: CGFloat {
        switch self {
        case .ownProfile: return 172
        case .publicCompact: return 148
        }
    }

    var height: CGFloat {
        switch self {
        case .ownProfile: return 240
        case .publicCompact: return 208
        }
    }

    /// Horizontal carousel frame height (card + breathing room).
    var carouselHeight: CGFloat {
        switch self {
        case .ownProfile: return 256
        case .publicCompact: return 222
        }
    }

    var cardSpacing: CGFloat {
        switch self {
        case .ownProfile: return 16
        case .publicCompact: return 14
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .ownProfile: return 22
        case .publicCompact: return 20
        }
    }

    var contentPadding: CGFloat {
        switch self {
        case .ownProfile: return 16
        case .publicCompact: return 14
        }
    }

    /// Neutral circular logo plate. Large enough that Jazz/Bulls crests share optical weight.
    var orbDiameter: CGFloat {
        switch self {
        case .ownProfile: return 118
        case .publicCompact: return 100
        }
    }

    var nameFontSize: CGFloat {
        switch self {
        case .ownProfile: return 16
        case .publicCompact: return 14
        }
    }

    var nameLineLimit: Int { 2 }

    var stackSpacing: CGFloat {
        switch self {
        case .ownProfile: return 12
        case .publicCompact: return 10
        }
    }

    var sportIconSize: CGFloat {
        switch self {
        case .ownProfile: return 12
        case .publicCompact: return 11
        }
    }

    var sportTitleSize: CGFloat {
        switch self {
        case .ownProfile: return 12
        case .publicCompact: return 11
        }
    }

    var trophyIconSize: CGFloat {
        switch self {
        case .ownProfile: return 13
        case .publicCompact: return 12
        }
    }

    var trophyHitSize: CGFloat {
        switch self {
        case .ownProfile: return 30
        case .publicCompact: return 26
        }
    }

    var myTeamLabelSize: CGFloat {
        switch self {
        case .ownProfile: return 7.5
        case .publicCompact: return 7
        }
    }
}

/// Shared rich Favorite Team card visual language used by own-profile Favorite Teams
/// and the public-profile Teams I Follow carousel.
///
/// Own-profile passes interactive trailing controls (trophy promote + remove).
/// Public-profile passes a read-only trophy treatment — no edit/remove affordances.
struct FavoriteTeamRichCard<Trailing: View>: View {
    let team: FavoriteTeam
    let isPrimary: Bool
    let style: FavoriteTeamRichCardStyle
    let languageCode: String
    var isAnimatingSelection: Bool = false
    var isAnimatingDemotion: Bool = false
    private let trailingControls: Trailing

    @Environment(\.colorScheme) private var colorScheme

    init(
        team: FavoriteTeam,
        isPrimary: Bool,
        style: FavoriteTeamRichCardStyle,
        languageCode: String,
        isAnimatingSelection: Bool = false,
        isAnimatingDemotion: Bool = false,
        @ViewBuilder trailingControls: () -> Trailing
    ) {
        self.team = team
        self.isPrimary = isPrimary
        self.style = style
        self.languageCode = languageCode
        self.isAnimatingSelection = isAnimatingSelection
        self.isAnimatingDemotion = isAnimatingDemotion
        self.trailingControls = trailingControls()
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: style.stackSpacing) {
                SportsIdentityArtworkView(
                    favoriteTeam: team,
                    diameter: style.orbDiameter,
                    plate: .neutralLogo
                )
                .accessibilityHidden(true)

                Text(team.name)
                    .font(.system(size: style.nameFontSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .lineLimit(style.nameLineLimit)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.82)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(
                        isPrimary
                            ? MyTeamDisplayModel(team: team).accessibilityLabel(languageCode: languageCode)
                            : team.name
                    )

                sportBadge
            }
            .padding(.top, style.contentPadding)
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            trailingControls
                .padding(.top, 8)
                .padding(.trailing, 8)
        }
        .frame(width: style.width, height: style.height, alignment: .top)
        .background {
            cardShape
                .fill(FGAdaptiveSurface.cardElevated(colorScheme))
                .overlay {
                    cardShape
                        .strokeBorder(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 1.2 : 1.6), lineWidth: 1)
                }
        }
        .clipShape(cardShape)
        .contentShape(cardShape)
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.08),
            radius: isPrimary ? 12 : isAnimatingDemotion ? 11 : 10,
            y: isPrimary ? 6 : 5
        )
        .accessibilityElement(children: .combine)
    }

    private var sportBadge: some View {
        let glyphKind = FanGeoSportMarkCatalog.kind(sport: team.sport.rawValue)
        let pillFill = colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.05)
        let pillStroke = colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.06)

        return HStack(spacing: 6) {
            FanGeoSportMarkGlyph(kind: glyphKind)
                .stroke(
                    FGColor.secondaryText(colorScheme),
                    style: StrokeStyle(lineWidth: 1.05, lineCap: .round, lineJoin: .round)
                )
                .frame(width: style.sportIconSize, height: style.sportIconSize)
                .accessibilityHidden(true)
            Text(team.sport.chipTitle)
                .font(.system(size: style.sportTitleSize, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            Capsule(style: .continuous)
                .fill(pillFill)
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(pillStroke, lineWidth: 0.75)
                }
        }
        .accessibilityHidden(true)
    }
}

extension FavoriteTeamRichCard where Trailing == FavoriteTeamRichCardReadOnlyTrophy {
    /// Public / read-only card with the same gold Favorite Team / outline trophy treatment as own profile,
    /// without promote or remove controls.
    init(
        team: FavoriteTeam,
        isPrimary: Bool,
        style: FavoriteTeamRichCardStyle,
        languageCode: String
    ) {
        self.init(
            team: team,
            isPrimary: isPrimary,
            style: style,
            languageCode: languageCode,
            isAnimatingSelection: false,
            isAnimatingDemotion: false
        ) {
            FavoriteTeamRichCardReadOnlyTrophy(
                isPrimary: isPrimary,
                style: style,
                languageCode: languageCode
            )
        }
    }
}

/// Visual-only trophy / Favorite Team treatment matching own-profile Favorite Teams (non-interactive).
struct FavoriteTeamRichCardReadOnlyTrophy: View {
    let isPrimary: Bool
    let style: FavoriteTeamRichCardStyle
    let languageCode: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        FavoriteTeamRichCardTrophyGlyph(
            isPrimary: isPrimary,
            style: style,
            languageCode: languageCode,
            showsMyTeamLabel: isPrimary,
            colorScheme: colorScheme
        )
        .accessibilityHidden(true)
    }
}

/// Shared trophy chrome for light Favorite Team cards.
struct FavoriteTeamRichCardTrophyGlyph: View {
    let isPrimary: Bool
    let style: FavoriteTeamRichCardStyle
    let languageCode: String
    var showsMyTeamLabel: Bool
    var isAnimatingSelection: Bool = false
    var reduceMotion: Bool = true
    var colorScheme: ColorScheme

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Image(systemName: "trophy")
                    .opacity(isPrimary ? 0 : 1)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                Image(systemName: "trophy.fill")
                    .opacity(isPrimary ? 1 : 0)
                    .foregroundStyle(FGColor.accentYellow)
            }
            .font(.system(size: style.trophyIconSize, weight: .heavy))
            .frame(width: style.trophyHitSize, height: style.trophyHitSize)
            .background {
                Circle()
                    .fill(
                        isPrimary
                            ? FGColor.accentYellow.opacity(colorScheme == .dark ? 0.22 : 0.16)
                            : (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.04))
                    )
                    .overlay {
                        Circle()
                            .strokeBorder(
                                isPrimary
                                    ? FGColor.accentYellow.opacity(0.70)
                                    : (colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.10)),
                                lineWidth: 1
                            )
                    }
            }
            .shadow(color: isPrimary ? FGColor.accentYellow.opacity(0.28) : .clear, radius: 6, y: 1)
            .scaleEffect(isAnimatingSelection && !reduceMotion ? 1.13 : 1.0)
            .accessibilityHidden(true)

            if showsMyTeamLabel && isPrimary {
                Text(L10n.t("my_team", languageCode: languageCode))
                    .font(.system(size: style.myTeamLabelSize, weight: .heavy, design: .rounded))
                    .textCase(.uppercase)
                    .tracking(0.15)
                    .foregroundStyle(FGColor.accentYellow)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
    }
}
