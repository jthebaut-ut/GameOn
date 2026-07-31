import PhotosUI
import SwiftUI

// MARK: - Section chrome (type-erased)

enum ProfileIdentitySectionHierarchy {
    case hero
    case primary
    case secondary
    case utility
}

/// Shared section chrome that always erases content so parent LazyVStacks stay shallow.
struct ProfileIdentitySectionChrome: View {
    let hierarchy: ProfileIdentitySectionHierarchy
    let accent: [Color]?
    /// Curated hero background; used only when `hierarchy == .hero`.
    var profileBackgroundKey: ProfileBackgroundKey = .fangeo
    private let erasedContent: AnyView

    @Environment(\.colorScheme) private var colorScheme

    init<Content: View>(
        hierarchy: ProfileIdentitySectionHierarchy,
        accent: [Color]?,
        profileBackgroundKey: ProfileBackgroundKey = .fangeo,
        @ViewBuilder content: () -> Content
    ) {
        self.hierarchy = hierarchy
        self.accent = accent
        self.profileBackgroundKey = profileBackgroundKey
        self.erasedContent = AnyView(content())
    }

    var body: some View {
        AnyView(chromeBody)
    }

    private var chromeBody: some View {
        erasedContent
            .padding(innerPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(sectionBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(alignment: .top) {
                if let accent {
                    topAccent(accent)
                }
            }
            .overlay(sectionBorder)
            .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowY)
            // Hero uses parent adaptive outer inset so the card spans nearly full width;
            // other sections keep their existing internal chrome inset (unchanged).
            .padding(.horizontal, hierarchy == .hero ? 0 : 16)
    }

    private var innerPadding: EdgeInsets {
        switch hierarchy {
        case .hero:
            EdgeInsets(top: 0, leading: 0, bottom: ProfileHeroMetrics.heroBottomPadding, trailing: 0)
        case .primary:
            EdgeInsets(top: 16, leading: 14, bottom: 16, trailing: 14)
        case .secondary:
            EdgeInsets(top: 16, leading: 13, bottom: 16, trailing: 13)
        case .utility:
            EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)
        }
    }

    private var cornerRadius: CGFloat {
        switch hierarchy {
        case .hero: ProfileHeroMetrics.heroCornerRadius
        case .primary: 24
        case .secondary, .utility: 22
        }
    }

    @ViewBuilder
    private var sectionBackground: some View {
        switch hierarchy {
        case .hero:
            ProfileBackgroundHeroFill(
                option: ProfileBackgroundCatalog.option(for: profileBackgroundKey),
                artworkHeight: ProfileHeroMetrics.artworkHeight
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        case .primary, .secondary, .utility:
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: backgroundColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }

    private var backgroundColors: [Color] {
        switch hierarchy {
        case .hero:
            return [
                Color.white.opacity(colorScheme == .dark ? 0.085 : 0.98),
                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.075 : 0.070),
                FGColor.accentGreen.opacity(colorScheme == .dark ? 0.045 : 0.050)
            ]
        case .primary:
            return [
                Color.white.opacity(colorScheme == .dark ? 0.075 : 0.96),
                FGColor.accentGreen.opacity(colorScheme == .dark ? 0.060 : 0.055),
                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.050 : 0.045)
            ]
        case .secondary:
            return [
                Color.white.opacity(colorScheme == .dark ? 0.050 : 0.88),
                Color.white.opacity(colorScheme == .dark ? 0.030 : 0.64),
                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.035 : 0.030)
            ]
        case .utility:
            return [
                Color.white.opacity(colorScheme == .dark ? 0.040 : 0.80),
                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.035 : 0.032)
            ]
        }
    }

    private var sectionBorder: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: borderColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: borderWidth
            )
    }

    private var borderColors: [Color] {
        switch hierarchy {
        case .hero:
            return [
                Color.white.opacity(colorScheme == .dark ? 0.13 : 0.92),
                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.18 : 0.18),
                Color.black.opacity(colorScheme == .dark ? 0.04 : 0.08)
            ]
        case .primary:
            return [
                Color.white.opacity(colorScheme == .dark ? 0.10 : 0.86),
                FGColor.accentGreen.opacity(colorScheme == .dark ? 0.16 : 0.17),
                Color.black.opacity(colorScheme == .dark ? 0.03 : 0.065)
            ]
        case .secondary:
            return [
                Color.white.opacity(colorScheme == .dark ? 0.075 : 0.72),
                Color.black.opacity(colorScheme == .dark ? 0.025 : 0.055)
            ]
        case .utility:
            return [
                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.10 : 0.10),
                Color.black.opacity(colorScheme == .dark ? 0.02 : 0.05)
            ]
        }
    }

    private var borderWidth: CGFloat {
        switch hierarchy {
        case .hero, .primary: 1
        case .secondary, .utility: 0.85
        }
    }

    private var shadowColor: Color {
        switch hierarchy {
        case .hero:
            Color.black.opacity(colorScheme == .dark ? 0.26 : 0.075)
        case .primary:
            FGColor.accentBlue.opacity(colorScheme == .dark ? 0.13 : 0.075)
        case .secondary:
            Color.black.opacity(colorScheme == .dark ? 0.14 : 0.040)
        case .utility:
            FGColor.accentBlue.opacity(colorScheme == .dark ? 0.08 : 0.035)
        }
    }

    private var shadowRadius: CGFloat {
        switch hierarchy {
        case .hero: 20
        case .primary: 16
        case .secondary: 10
        case .utility: 8
        }
    }

    private var shadowY: CGFloat {
        switch hierarchy {
        case .hero: 10
        case .primary: 8
        case .secondary: 5
        case .utility: 3
        }
    }

    private func topAccent(_ accent: [Color]) -> some View {
        let baseColors = accent.isEmpty ? [FGColor.accentBlue] : accent
        let gradientColors = baseColors.count == 1 ? [baseColors[0], baseColors[0]] : baseColors
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(
                LinearGradient(
                    colors: gradientColors.map {
                        $0.opacity(colorScheme == .dark ? 0.76 : 0.58)
                    },
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 4)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Hero

struct ProfileIdentityHeroStripColumn: Identifiable {
    enum Kind: String {
        case myTeam
        case nationalTeam
        case homeCrowd
        case homeCity
        case fanSince
    }

    let id: Kind
    let title: String
    let subtitle: String
    var action: (() -> Void)? = nil
    /// Used only for `.nationalTeam` icon rendering.
    var nationalTeamFlag: String? = nil
    /// Used only for `.myTeam` logo rendering.
    var favoriteTeam: FavoriteTeam? = nil
}

/// Hero leaf: avatar, identity text, Fan XP, edit affordances, identity strip.
/// Kept outside `ProfileIdentityCard` so its generic type graph stays shallow.
struct ProfileIdentityHeroSection: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var selectedAvatarItem: PhotosPickerItem?
    let isUploadingAvatar: Bool
    let isSavingIdentity: Bool
    let localAvatarPreviewImage: UIImage?
    let displayName: String
    let handleLine: String
    let bioLine: String
    let identityCards: [ProfileHeroIdentityCardItem]
    let onEditDisplayName: () -> Void
    let onEditBio: () -> Void
    let onEditProfile: () -> Void
    let onShareProfile: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private static let avatarDiameter: CGFloat = ProfileHeroMetrics.avatarDiameter
    private static let avatarRingWidth: CGFloat = 4
    private static let avatarOuterPadding: CGFloat = 4
    private static let cameraButtonDiameter: CGFloat = 31
    private static let cameraIconSize: CGFloat = 11.5

    var body: some View {
        // Erase hero at its boundary — parent section chrome only sees AnyView.
        AnyView(heroContent)
    }

    private var heroContent: some View {
        VStack(alignment: .leading, spacing: ProfileHeroMetrics.identityToCardsSpacing) {
            ProfileIdentityHeroHeaderRow(
                viewModel: viewModel,
                selectedAvatarItem: $selectedAvatarItem,
                isUploadingAvatar: isUploadingAvatar,
                isSavingIdentity: isSavingIdentity,
                localAvatarPreviewImage: localAvatarPreviewImage,
                displayName: displayName,
                handleLine: handleLine,
                bioLine: bioLine,
                onEditDisplayName: onEditDisplayName,
                onEditBio: onEditBio,
                onEditProfile: onEditProfile,
                onShareProfile: onShareProfile
            )

            if !identityCards.isEmpty {
                ProfileHeroIdentityCardsRow(cards: identityCards)
            }
        }
        .padding(.horizontal, ProfileHeroMetrics.heroContentHorizontalPadding)
        .padding(.top, ProfileHeroMetrics.identityTopInset)
        .padding(.bottom, 0)
    }
}

private struct ProfileIdentityHeroHeaderRow: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var selectedAvatarItem: PhotosPickerItem?
    let isUploadingAvatar: Bool
    let isSavingIdentity: Bool
    let localAvatarPreviewImage: UIImage?
    let displayName: String
    let handleLine: String
    let bioLine: String
    let onEditDisplayName: () -> Void
    let onEditBio: () -> Void
    let onEditProfile: () -> Void
    let onShareProfile: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                PhotosPicker(selection: $selectedAvatarItem, matching: .images) {
                    ProfileIdentityHeroAvatarStack(
                        viewModel: viewModel,
                        localAvatarPreviewImage: localAvatarPreviewImage,
                        displayName: displayName,
                        isUploadingAvatar: isUploadingAvatar
                    )
                }
                .disabled(isUploadingAvatar || isSavingIdentity)
                .buttonStyle(.plain)
                .accessibilityLabel("Update profile photo")
                // Avatar bridges curated artwork into the light identity surface.
                .profileHeroAvatarOverlap()

                ProfileIdentityHeroTextColumn(
                    displayName: displayName,
                    handleLine: handleLine,
                    bioLine: bioLine,
                    totalXP: viewModel.currentUserFanXP.totalXP,
                    languageCode: appLanguageRaw,
                    onEditDisplayName: onEditDisplayName,
                    onEditBio: onEditBio
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                // Soft readability assist only — continuous with the white dissolve (not a hard slab).
                // Dark Mode: no panel; text sits on the hero surface like Light Mode.
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .background {
                    if colorScheme == .light {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.55))
                    }
                }
            }

            // Full-width action row (same pattern as public profile) so "Edit Profile"
            // is never squeezed by the avatar column.
            ProfileIdentityHeroActionRow(
                onEditProfile: onEditProfile,
                onShareProfile: onShareProfile
            )
        }
    }
}

private struct ProfileIdentityHeroTextColumn: View {
    let displayName: String
    let handleLine: String
    let bioLine: String
    let totalXP: Int
    let languageCode: String
    let onEditDisplayName: () -> Void
    let onEditBio: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onEditDisplayName) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)

                    Text(handleLine)
                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit display name and handle")

            FanXpSummaryLine(
                totalXP: totalXP,
                languageCode: languageCode
            )
            .padding(.top, 3)

            Button(action: onEditBio) {
                Text(
                    bioLine.isEmpty
                        ? L10n.t("profile_bio_placeholder", languageCode: languageCode)
                        : bioLine
                )
                    .font(.system(size: 14.5, weight: .medium, design: .rounded))
                    .foregroundStyle(bioLine.isEmpty ? FGColor.mutedText(colorScheme) : FGColor.primaryText(colorScheme).opacity(0.88))
                    .lineLimit(3)
                    .lineSpacing(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(bioLine.isEmpty ? "Add bio" : "Edit bio")
            .padding(.top, 5)
        }
    }
}

private enum ProfileIdentityHeroActionMetrics {
    /// Visible control height at default Dynamic Type (compact Apple-style).
    static let visualHeight: CGFloat = 40
    /// Accessibility / HIG minimum tap target at default size.
    static let minHitHeight: CGFloat = 44
    /// Row height — the hit target, not the visible pill.
    static let rowHeight: CGFloat = minHitHeight
    static let cornerRadius: CGFloat = 12
    static let interButtonSpacing: CGFloat = 10
    static let iconPointSize: CGFloat = 15
    static let iconTextSpacing: CGFloat = 4
    /// Tightened from 10 so "Edit Profile" fits beside Share without ellipsis.
    static let horizontalContentPadding: CGFloat = 8
    /// Edit stays the primary action without dominating the row.
    static let editWidthFraction: CGFloat = 0.72
    /// Reserve used until Share reports its measured width.
    static let shareFallbackWidth: CGFloat = 88
}

/// Intrinsic width of the Share label so Edit can size around it.
private struct ProfileHeroActionShareWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Own-profile action row: Edit (primary, ~72% of the row) + Share (secondary).
///
/// Edit is sized rather than flexible — two flexible pills would split the row
/// 50/50, which reads as two co-equal actions.
private struct ProfileIdentityHeroActionRow: View {
    let onEditProfile: () -> Void
    let onShareProfile: () -> Void

    @State private var shareIntrinsicWidth: CGFloat = 0
    @ScaledMetric(relativeTo: .footnote) private var rowHeight = ProfileIdentityHeroActionMetrics.rowHeight
    @ScaledMetric(relativeTo: .footnote) private var shareFallbackWidth = ProfileIdentityHeroActionMetrics.shareFallbackWidth

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: ProfileIdentityHeroActionMetrics.interButtonSpacing) {
                ProfileIdentityHeroEditButton(action: onEditProfile)
                    .frame(width: editWidth(inRowWidth: proxy.size.width))
                ProfileIdentityHeroShareButton(action: onShareProfile)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .frame(height: rowHeight)
        .onPreferenceChange(ProfileHeroActionShareWidthKey.self) { shareIntrinsicWidth = $0 }
    }

    /// Edit takes its share of the row, minus whatever Share actually needs —
    /// so long localizations ("Compartilhar", "Поделиться") stay untruncated
    /// instead of overflowing a fixed reserve. `nil` falls back to flexible
    /// sizing when the row is too narrow to give Edit any width at all.
    private func editWidth(inRowWidth rowWidth: CGFloat) -> CGFloat? {
        let shareWidth = max(shareFallbackWidth, shareIntrinsicWidth)
        let remainderForEdit = rowWidth
            - ProfileIdentityHeroActionMetrics.interButtonSpacing
            - shareWidth
        let proportional = rowWidth * ProfileIdentityHeroActionMetrics.editWidthFraction
        let width = min(proportional, remainderForEdit)
        return width > 0 ? width : nil
    }
}

private struct ProfileIdentityHeroEditButton: View {
    let action: () -> Void
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @ScaledMetric(relativeTo: .footnote) private var visualHeight = ProfileIdentityHeroActionMetrics.visualHeight
    @ScaledMetric(relativeTo: .footnote) private var minHitHeight = ProfileIdentityHeroActionMetrics.minHitHeight
    @ScaledMetric(relativeTo: .body) private var iconPointSize = ProfileIdentityHeroActionMetrics.iconPointSize

    var body: some View {
        Button(action: action) {
            HStack(spacing: ProfileIdentityHeroActionMetrics.iconTextSpacing) {
                Image(systemName: "pencil")
                    .font(.system(size: iconPointSize, weight: .semibold))
                    .layoutPriority(1)
                Text(L10n.t("edit_profile_hero_button", languageCode: appLanguageRaw))
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    // Guards long localizations at accessibility sizes now that
                    // the button no longer takes the row's whole flexible width.
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, ProfileIdentityHeroActionMetrics.horizontalContentPadding)
            .frame(maxWidth: .infinity)
            .frame(height: visualHeight)
            .background {
                RoundedRectangle(
                    cornerRadius: ProfileIdentityHeroActionMetrics.cornerRadius,
                    style: .continuous
                )
                .fill(FGColor.accentBlue)
            }
            .frame(minHeight: minHitHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Only relevant in the unsized fallback path (see `ProfileIdentityHeroActionRow`).
        .layoutPriority(1)
        .accessibilityLabel(L10n.t("edit_profile", languageCode: appLanguageRaw))
    }
}

private struct ProfileIdentityHeroShareButton: View {
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @ScaledMetric(relativeTo: .footnote) private var visualHeight = ProfileIdentityHeroActionMetrics.visualHeight
    @ScaledMetric(relativeTo: .footnote) private var minHitHeight = ProfileIdentityHeroActionMetrics.minHitHeight
    @ScaledMetric(relativeTo: .body) private var iconPointSize = ProfileIdentityHeroActionMetrics.iconPointSize

    var body: some View {
        Button(action: action) {
            HStack(spacing: ProfileIdentityHeroActionMetrics.iconTextSpacing) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: iconPointSize, weight: .semibold))
                Text(L10n.t("share_profile_hero_button", languageCode: appLanguageRaw))
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(FGColor.accentBlue)
            // Label never truncates; only the pill around it flexes.
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, ProfileIdentityHeroActionMetrics.horizontalContentPadding)
            .background {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ProfileHeroActionShareWidthKey.self,
                        value: geo.size.width
                    )
                }
            }
            // Share absorbs whatever the sized Edit button leaves in the row.
            .frame(maxWidth: .infinity)
            .frame(height: visualHeight)
            .background {
                RoundedRectangle(
                    cornerRadius: ProfileIdentityHeroActionMetrics.cornerRadius,
                    style: .continuous
                )
                .fill(Color.white.opacity(colorScheme == .dark ? 0.12 : 1))
            }
            .overlay {
                RoundedRectangle(
                    cornerRadius: ProfileIdentityHeroActionMetrics.cornerRadius,
                    style: .continuous
                )
                .strokeBorder(FGColor.accentBlue.opacity(0.55), lineWidth: 1)
            }
            .frame(minHeight: minHitHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("share_profile", languageCode: appLanguageRaw))
    }
}

private struct ProfileIdentityHeroAvatarStack: View {
    @ObservedObject var viewModel: MapViewModel
    let localAvatarPreviewImage: UIImage?
    let displayName: String
    let isUploadingAvatar: Bool

    @Environment(\.colorScheme) private var colorScheme

    private static let avatarDiameter: CGFloat = ProfileHeroMetrics.avatarDiameter
    private static let avatarRingWidth: CGFloat = 4
    private static let avatarOuterPadding: CGFloat = 4
    private static let cameraButtonDiameter: CGFloat = 31
    private static let cameraIconSize: CGFloat = 11.5

    private var pokesBadgeVisible: Bool {
        viewModel.hasUnseenPokes
    }

    private var avatarPresentationIdentity: String {
        [
            viewModel.currentUserAuthId?.uuidString ?? "none",
            viewModel.currentUserAvatarURL,
            viewModel.currentUserAvatarThumbnailURL,
            viewModel.currentUserAvatarDisplayRefreshToken.uuidString
        ].joined(separator: "|")
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ProfileIdentityHeroAvatarCore(
                viewModel: viewModel,
                localAvatarPreviewImage: localAvatarPreviewImage,
                displayName: displayName,
                isUploadingAvatar: isUploadingAvatar,
                presentationIdentity: avatarPresentationIdentity
            )

            if pokesBadgeVisible {
                PokesUnseenAvatarBadge(style: .profileHero)
                    .offset(x: 3, y: 1)
            }
        }
        .onAppear {
            DebugLogGate.debug("[PokesBadgeUI] avatarBadge visible=\(pokesBadgeVisible)")
        }
        .onChange(of: pokesBadgeVisible) { _, visible in
            DebugLogGate.debug("[PokesBadgeUI] avatarBadge visible=\(visible)")
        }
    }
}

private struct ProfileIdentityHeroAvatarCore: View {
    @ObservedObject var viewModel: MapViewModel
    let localAvatarPreviewImage: UIImage?
    let displayName: String
    let isUploadingAvatar: Bool
    let presentationIdentity: String

    @Environment(\.colorScheme) private var colorScheme

    private static let avatarDiameter: CGFloat = ProfileHeroMetrics.avatarDiameter
    private static let avatarRingWidth: CGFloat = 4
    private static let avatarOuterPadding: CGFloat = 4
    private static let cameraButtonDiameter: CGFloat = 31
    private static let cameraIconSize: CGFloat = 11.5

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            UserAvatarView(
                avatarThumbnailURL: viewModel.currentUserAvatarThumbnailURL,
                avatarURL: viewModel.currentUserAvatarURL,
                avatarDisplayRefreshToken: viewModel.currentUserAvatarDisplayRefreshToken,
                localPreviewImage: localAvatarPreviewImage,
                displayName: displayName,
                email: viewModel.currentUserEmail,
                size: Self.avatarDiameter,
                fallbackStyle: .lightOnWhiteChrome,
                imagePlaceholderTint: FGColor.accentBlue
            )
            .overlay {
                Circle()
                    .strokeBorder(
                        AngularGradient(
                            colors: [
                                FGColor.accentBlue,
                                FGColor.accentGreen,
                                Color(red: 0.98, green: 0.67, blue: 0.33),
                                FGColor.accentBlue
                            ],
                            center: .center
                        ),
                        lineWidth: Self.avatarRingWidth
                    )
            }
            .padding(Self.avatarOuterPadding)
            .background(Circle().fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.96)))
            .shadow(color: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.18 : 0.16), radius: 12, y: 5)
            .id(presentationIdentity)
            .onAppear {
#if DEBUG
                ProfileAvatarDebug.avatarViewResolved(
                    context: "ProfileIdentityHeroAvatarCore",
                    thumbnailInput: viewModel.currentUserAvatarThumbnailURL,
                    fullInput: viewModel.currentUserAvatarURL,
                    displayURLString: ImageDisplayURL.forListDisplay(
                        thumbnail: viewModel.currentUserAvatarThumbnailURL,
                        full: viewModel.currentUserAvatarURL,
                        refreshToken: viewModel.currentUserAvatarDisplayRefreshToken
                    ),
                    urlParseSucceeded: ImageDisplayURL.forListDisplay(
                        thumbnail: viewModel.currentUserAvatarThumbnailURL,
                        full: viewModel.currentUserAvatarURL,
                        refreshToken: viewModel.currentUserAvatarDisplayRefreshToken
                    ).flatMap { URL(string: $0) } != nil,
                    fallbackReason: viewModel.currentUserAvatarURL.isEmpty
                        && viewModel.currentUserAvatarThumbnailURL.isEmpty
                        ? "view_model_avatar_urls_empty"
                        : "awaiting_UserAvatarView_image_layer"
                )
#endif
            }

            Circle()
                .fill(Color(.secondarySystemGroupedBackground))
                .frame(width: Self.cameraButtonDiameter, height: Self.cameraButtonDiameter)
                .overlay {
                    ProfileHeroAvatarCameraGlyph(
                        isUploading: isUploadingAvatar,
                        iconSize: Self.cameraIconSize,
                        tint: FGColor.accentGreen
                    )
                }
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.14 : 0.95), lineWidth: 1.75)
                }
                .offset(x: 5, y: 5)
        }
    }
}

private struct ProfileIdentityHeroIdentityPanel: View {
    let columns: [ProfileIdentityHeroStripColumn]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                if index > 0 {
                    Rectangle()
                        .fill(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.5 : 0.75))
                        .frame(width: 1)
                        .padding(.vertical, 8)
                }

                ProfileIdentityHeroIdentityColumn(
                    column: column,
                    nationalTeamFlag: column.id == .nationalTeam ? column.nationalTeamFlag : nil,
                    favoriteTeam: column.id == .myTeam ? column.favoriteTeam : nil
                )
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, index == 0 || index == columns.count - 1 ? 2 : 6)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(panelFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(panelBorder, lineWidth: 1)
        }
    }

    private var panelFill: Color {
        colorScheme == .dark
            ? Color(red: 0.10, green: 0.14, blue: 0.20).opacity(0.92)
            : Color(red: 0.93, green: 0.95, blue: 0.99)
    }

    private var panelBorder: Color {
        colorScheme == .dark
            ? FGColor.divider(colorScheme).opacity(0.65)
            : Color(red: 0.84, green: 0.88, blue: 0.95)
    }
}

private struct ProfileIdentityHeroIdentityColumn: View {
    let column: ProfileIdentityHeroStripColumn
    let nationalTeamFlag: String?
    var favoriteTeam: FavoriteTeam? = nil
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    var body: some View {
        AnyView(columnBody)
    }

    @ViewBuilder
    private var columnBody: some View {
        let content = VStack(spacing: 8) {
            ProfileIdentityHeroIdentityIcon(
                kind: column.id,
                nationalTeamFlag: nationalTeamFlag,
                favoriteTeam: favoriteTeam
            )

            Text(column.title)
                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme).opacity(0.92))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.82)
                .fixedSize(horizontal: false, vertical: true)

            Text(column.subtitle)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.82)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(columnAccessibilityLabel)

        if let action = column.action {
            Button(action: action) {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    private var columnAccessibilityLabel: String {
        switch column.id {
        case .myTeam:
            let heading = L10n.t("my_team", languageCode: appLanguageRaw)
            return "\(heading), \(column.title), \(column.subtitle)"
        case .nationalTeam:
            let heading = L10n.t("national_team", languageCode: appLanguageRaw)
            return "\(heading), \(column.title), \(column.subtitle)"
        case .homeCrowd, .homeCity, .fanSince:
            return "\(column.title), \(column.subtitle)"
        }
    }
}

private struct ProfileIdentityHeroIdentityIcon: View {
    let kind: ProfileIdentityHeroStripColumn.Kind
    let nationalTeamFlag: String?
    var favoriteTeam: FavoriteTeam? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        AnyView(iconBody)
    }

    @ViewBuilder
    private var iconBody: some View {
        switch kind {
        case .myTeam:
            if let favoriteTeam {
                SportsIdentityArtworkView(favoriteTeam: favoriteTeam, diameter: 38)
            } else {
                symbolIcon("trophy.fill", tint: FGColor.accentYellow)
            }
        case .nationalTeam:
            if let flag = nationalTeamFlag?.trimmingCharacters(in: .whitespacesAndNewlines),
               !flag.isEmpty {
                Text(flag)
                    .font(.system(size: 20))
                    .frame(width: 38, height: 38)
                    .background {
                        Circle()
                            .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.18 : 0.12))
                    }
            } else {
                symbolIcon("globe.americas.fill", tint: FGColor.accentGreen)
            }
        case .homeCrowd:
            symbolIcon("sportscourt.fill", tint: Color(red: 0.58, green: 0.42, blue: 0.92))
        case .homeCity:
            symbolIcon("mappin.and.ellipse", tint: Color(red: 0.22, green: 0.48, blue: 0.96))
        case .fanSince:
            symbolIcon("calendar", tint: Color(red: 0.22, green: 0.48, blue: 0.96))
        }
    }

    private func symbolIcon(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 38, height: 38)
            .background {
                Circle()
                    .fill(tint.opacity(colorScheme == .dark ? 0.2 : 0.12))
            }
    }
}

// MARK: - Favorite Teams / Home Venue / Open To / Pickup

struct ProfileIdentityFavoriteTeamsSection: View {
    let languageCode: String
    let teamsEmpty: Bool
    let onEdit: () -> Void
    /// Pre-erased carousel / empty-state content from the parent.
    let carouselContent: AnyView

    @Environment(\.colorScheme) private var colorScheme

    private static let bottomSpacing: CGFloat = 8

    var body: some View {
        AnyView(sectionBody)
    }

    private var sectionBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t("favorite_teams", languageCode: languageCode))
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(FGColor.accentBlue)
                        .textCase(.uppercase)
                        .tracking(0.78)
                    Text(
                        teamsEmpty
                            ? L10n.t("profile_shape_fan_identity", languageCode: languageCode)
                            : L10n.t("profile_show_off_fan_colors", languageCode: languageCode)
                    )
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.mutedText(colorScheme).opacity(0.82))
                }
                Spacer(minLength: 0)
                Button(action: onEdit) {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                            .font(.system(size: 9, weight: .bold))
                        Text(teamsEmpty ? "Add Teams" : L10n.t("Edit Teams", languageCode: languageCode))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(FGColor.accentBlue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background {
                        Capsule()
                            .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.14 : 0.10))
                    }
                }
                .buttonStyle(.plain)
            }

            carouselContent
        }
        .padding(.bottom, Self.bottomSpacing)
    }
}

struct ProfileIdentityHomeVenueSection: View {
    @ObservedObject var viewModel: MapViewModel

    var body: some View {
        AnyView(
            HomeCrowdProfileCardView(
                summary: viewModel.currentUserHomeCrowdVenue,
                isSelfProfile: true,
                onExploreVenue: viewModel.currentUserHomeCrowdVenue != nil
                    ? { viewModel.focusDiscoverOnHomeCrowdVenue() }
                    : nil,
                onChangeHomeCrowd: viewModel.currentUserHomeCrowdVenue != nil
                    ? { viewModel.focusDiscoverOnHomeCrowdVenue() }
                    : nil,
                onChooseHomeCrowd: viewModel.currentUserHomeCrowdVenue == nil
                    ? { viewModel.openDiscoverToChooseHomeCrowd() }
                    : nil
            )
        )
    }
}

struct ProfileIdentityOpenToSection: View {
    let languageCode: String
    let previewItems: [PublicProfileOpenToItem]
    let onEdit: () -> Void
    let onQuickRemove: (PublicProfileOpenToItem) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        AnyView(sectionBody)
    }

    private var sectionBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t("open_to", languageCode: languageCode))
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(FGColor.accentBlue)
                        .textCase(.uppercase)
                        .tracking(0.78)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(
                        previewItems.isEmpty
                            ? L10n.t("Tell fans what you're up for", languageCode: languageCode)
                            : L10n.t("What you're open to", languageCode: languageCode)
                    )
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.mutedText(colorScheme).opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(action: onEdit) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9, weight: .bold))
                        Text("Edit Open To")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(FGColor.accentBlue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background {
                        Capsule()
                            .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.14 : 0.10))
                    }
                }
                .buttonStyle(.plain)
            }

            SelfProfileOpenToPreviewGrid(items: previewItems, onRemove: onQuickRemove, onAdd: onEdit)
        }
    }
}

struct ProfileIdentityPickupGamesSection: View {
    @ObservedObject var viewModel: MapViewModel
    let userId: UUID
    let summary: PickupOrganizerSummary
    let languageCode: String

    var body: some View {
        AnyView(sectionBody)
    }

    private var sectionBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("pickup_games_section_title", languageCode: languageCode))
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(FGColor.accentBlue)
                .textCase(.uppercase)
                .tracking(0.78)

            ProfileIdentityOwnPickupOrganizerSection(
                viewModel: viewModel,
                userId: userId,
                summary: summary,
                usesExternalChrome: true
            )
        }
    }
}

/// Shallow camera/loading glyph for the profile hero avatar badge.
struct ProfileHeroAvatarCameraGlyph: View {
    let isUploading: Bool
    let iconSize: CGFloat
    let tint: Color

    var body: some View {
        AnyView(glyphContent)
    }

    @ViewBuilder
    private var glyphContent: some View {
        if isUploading {
            ProgressView()
                .controlSize(.small)
                .tint(tint)
        } else {
            Image(systemName: "camera.fill")
                .font(.system(size: iconSize, weight: .bold))
                .foregroundStyle(tint)
        }
    }
}
