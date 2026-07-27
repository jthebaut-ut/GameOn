import SwiftUI

/// Size / typography tokens for the shared rich Favorite Team card.
enum FavoriteTeamRichCardStyle: Equatable {
    /// Own Account → Favorite Teams carousel (source of truth dimensions).
    case ownProfile
    /// Public profile Teams I Follow — ~18% compact, still premium.
    case publicCompact

    var width: CGFloat {
        switch self {
        case .ownProfile: return 174
        case .publicCompact: return 148
        }
    }

    var height: CGFloat {
        switch self {
        case .ownProfile: return 164
        case .publicCompact: return 136
        }
    }

    /// Horizontal carousel frame height (card + breathing room).
    var carouselHeight: CGFloat {
        switch self {
        case .ownProfile: return 196
        case .publicCompact: return 152
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .ownProfile: return 24
        case .publicCompact: return 20
        }
    }

    var contentPadding: CGFloat {
        switch self {
        case .ownProfile: return 14
        case .publicCompact: return 12
        }
    }

    var orbDiameter: CGFloat {
        switch self {
        case .ownProfile: return 56
        case .publicCompact: return 46
        }
    }

    var nameFontSize: CGFloat {
        switch self {
        case .ownProfile: return 16
        case .publicCompact: return 14
        }
    }

    var stackSpacing: CGFloat {
        switch self {
        case .ownProfile: return 8
        case .publicCompact: return 6
        }
    }

    var sportIconSize: CGFloat {
        switch self {
        case .ownProfile: return 13
        case .publicCompact: return 11
        }
    }

    var sportTitleSize: CGFloat {
        switch self {
        case .ownProfile: return 11
        case .publicCompact: return 10
        }
    }

    var trophyIconSize: CGFloat {
        switch self {
        case .ownProfile: return 14
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
        case .ownProfile: return 8.5
        case .publicCompact: return 7.5
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

    private var sportAccent: Color {
        sportAccentColor(for: team.sport.chipTitle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style.stackSpacing) {
            HStack(alignment: .top, spacing: 8) {
                PremiumTeamIdentityOrb(team: team, diameter: style.orbDiameter)
                Spacer(minLength: 0)
                trailingControls
            }

            Text(team.name)
                .font(.system(size: style.nameFontSize, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .truncationMode(.tail)
                .minimumScaleFactor(0.78)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(
                    isPrimary
                        ? MyTeamDisplayModel(team: team).accessibilityLabel(languageCode: languageCode)
                        : team.name
                )

            sportBadge

            Spacer(minLength: 0)
        }
        .padding(style.contentPadding)
        .frame(width: style.width, height: style.height, alignment: .topLeading)
        .background {
            cardShape
                .fill(
                    LinearGradient(
                        colors: [
                            team.badgeColor.opacity(0.96),
                            FGColor.accentBlue.opacity(0.84),
                            Color(red: 0.09, green: 0.12, blue: 0.18).opacity(0.92)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    cardShape
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.34),
                                    Color.white.opacity(0.08)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
        }
        .clipShape(cardShape)
        .contentShape(cardShape)
        .overlay(alignment: .topLeading) {
            sportAccentStripe
        }
        .shadow(
            color: isPrimary
                ? FGColor.accentYellow.opacity(colorScheme == .dark ? 0.26 : 0.20)
                : isAnimatingDemotion
                    ? FGColor.accentYellow.opacity(colorScheme == .dark ? 0.10 : 0.08)
                    : team.badgeColor.opacity(colorScheme == .dark ? 0.18 : 0.16),
            radius: isPrimary ? 18 : isAnimatingDemotion ? 15 : 14,
            y: isPrimary ? 9 : 8
        )
        .accessibilityElement(children: .combine)
    }

    private var sportBadge: some View {
        HStack(spacing: 5) {
            Text(sportIcon(for: team.sport.chipTitle))
                .font(.system(size: style.sportIconSize))
            Text(team.sport.chipTitle)
                .font(.system(size: style.sportTitleSize, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.84))
        .padding(.horizontal, style == .publicCompact ? 6 : 7)
        .padding(.vertical, 3)
        .background {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.13))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75)
                }
        }
    }

    private var sportAccentStripe: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            sportAccent.opacity(colorScheme == .dark ? 0.62 : 0.50),
                            sportAccent.opacity(colorScheme == .dark ? 0.22 : 0.16),
                            Color.white.opacity(0.02),
                            Color.clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: style == .publicCompact ? 2.5 : 3)
                .shadow(
                    color: sportAccent.opacity(colorScheme == .dark ? 0.30 : 0.18),
                    radius: 8,
                    y: 2
                )
            Spacer(minLength: 0)
        }
        .clipShape(cardShape)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension FavoriteTeamRichCard where Trailing == FavoriteTeamRichCardReadOnlyTrophy {
    /// Public / read-only card with the same gold MY TEAM / outline trophy treatment as own profile,
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

/// Visual-only trophy / MY TEAM treatment matching own-profile Favorite Teams (non-interactive).
struct FavoriteTeamRichCardReadOnlyTrophy: View {
    let isPrimary: Bool
    let style: FavoriteTeamRichCardStyle
    let languageCode: String

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Image(systemName: "trophy")
                    .opacity(isPrimary ? 0 : 1)
                    .foregroundStyle(Color.white.opacity(0.92))
                Image(systemName: "trophy.fill")
                    .opacity(isPrimary ? 1 : 0)
                    .foregroundStyle(FGColor.accentYellow)
            }
            .font(.system(size: style.trophyIconSize, weight: .heavy))
            .frame(width: style.trophyHitSize, height: style.trophyHitSize)
            .background {
                Circle()
                    .fill(isPrimary ? FGColor.accentYellow.opacity(0.18) : Color.black.opacity(0.18))
                    .overlay {
                        Circle()
                            .strokeBorder(
                                isPrimary ? FGColor.accentYellow.opacity(0.64) : Color.white.opacity(0.22),
                                lineWidth: 1
                            )
                    }
            }
            .shadow(color: isPrimary ? FGColor.accentYellow.opacity(0.45) : .clear, radius: 8, y: 2)
            .accessibilityHidden(true)

            if isPrimary {
                Text(L10n.t("my_team", languageCode: languageCode))
                    .font(.system(size: style.myTeamLabelSize, weight: .heavy, design: .rounded))
                    .textCase(.uppercase)
                    .tracking(0.2)
                    .foregroundStyle(FGColor.accentYellow)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .accessibilityHidden(true)
    }
}
