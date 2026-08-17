import SwiftUI

// MARK: - Layout metrics (testable)

enum ProfileMyTeamsCarouselLayout {
    /// Target visible cards so horizontal scroll is obvious (≈2.5–3).
    static let visibleCardCount: CGFloat = 2.65
    static let cardSpacing: CGFloat = 10
    static let minCardWidth: CGFloat = 108
    static let maxCardWidth: CGFloat = 138
    static let cardHeight: CGFloat = 168
    static let logoSize: CGFloat = 48
    static let horizontalInset: CGFloat = 2

    static func cardWidth(containerWidth: CGFloat) -> CGFloat {
        let usable = max(0, containerWidth - horizontalInset * 2)
        let raw = (usable - cardSpacing * 2) / visibleCardCount
        return min(maxCardWidth, max(minCardWidth, raw))
    }
}

// MARK: - Carousel membership card

/// Compact vertical Team card for the profile My Teams horizontal carousel.
struct ProfileMyTeamsMembershipCard: View {
    let membership: ProfileFanTeamMembership
    let languageCode: String
    var cardWidth: CGFloat = ProfileMyTeamsCarouselLayout.minCardWidth
    var onTap: (() -> Void)? = nil
    var displayRefreshToken: UUID? = nil

    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color {
        FanTeamColorTheme.accentColor(colorHex: membership.colorHex, colorScheme: colorScheme)
            ?? FGColor.intentTeams
    }

    private var isInteractive: Bool { onTap != nil && membership.viewerCanOpen }

    var body: some View {
        let content = cardContent
            .frame(width: cardWidth, height: ProfileMyTeamsCarouselLayout.cardHeight, alignment: .top)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(FGColor.cardBackground(colorScheme))
            }
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(
                    topLeadingRadius: 18,
                    bottomLeadingRadius: 18,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0,
                    style: .continuous
                )
                .fill(accent)
                .frame(width: 4)
                .accessibilityHidden(true)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        accent.opacity(colorScheme == .dark ? 0.28 : 0.14),
                        lineWidth: 1
                    )
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.07),
                radius: 10,
                x: 0,
                y: 4
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                ProfileMyTeamsPresentation.accessibilityLabel(
                    membership: membership,
                    languageCode: languageCode,
                    opensTeam: isInteractive
                )
            )
            .accessibilityAddTraits(isInteractive ? .isButton : [])

        if let onTap, membership.viewerCanOpen {
            Button(action: onTap) {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    private var cardContent: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                FanTeamMarkView(
                    sport: membership.sport,
                    logoURL: membership.logoURL,
                    logoThumbnailURL: membership.logoThumbnailURL,
                    colorHex: membership.colorHex,
                    size: ProfileMyTeamsCarouselLayout.logoSize,
                    preferDetailURL: false,
                    displayRefreshToken: displayRefreshToken
                )
                .frame(maxWidth: .infinity)

                if isInteractive {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(FGColor.mutedText(colorScheme).opacity(0.55))
                        .padding(.top, 2)
                        .padding(.trailing, 2)
                        .accessibilityHidden(true)
                }
            }

            VStack(spacing: 3) {
                Text(membership.name)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .top)

                if !membership.sportDisplayLabel.isEmpty {
                    Text(membership.sportDisplayLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }

            Spacer(minLength: 0)

            FanTeamRoleBadgeView(
                role: membership.role,
                languageCode: languageCode,
                showsTitle: true,
                compact: true
            )
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }
}

// MARK: - Section header

struct ProfileMyTeamsSectionHeader: View {
    let languageCode: String
    var showsEmptyHint: Bool = false
    var onViewAll: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("profile_my_teams_title", languageCode: languageCode))
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(FGColor.accentBlue)
                    .textCase(.uppercase)
                    .tracking(0.78)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel(L10n.t("profile_my_teams_a11y_section", languageCode: languageCode))

                Text(L10n.t("profile_my_teams_subtitle", languageCode: languageCode))
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(FGColor.mutedText(colorScheme).opacity(0.82))

                if showsEmptyHint {
                    Text(L10n.t("profile_my_teams_empty", languageCode: languageCode))
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.mutedText(colorScheme).opacity(0.75))
                        .padding(.top, 1)
                }
            }

            Spacer(minLength: 0)

            if let onViewAll {
                Button(action: onViewAll) {
                    HStack(spacing: 2) {
                        Text(L10n.t("profile_my_teams_view_all", languageCode: languageCode))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(FGColor.accentBlue)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("profile_my_teams_view_all", languageCode: languageCode))
            }
        }
    }
}

// MARK: - Empty state

struct ProfileMyTeamsEmptyStateView: View {
    let languageCode: String
    var onCreateTeam: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("profile_my_teams_empty_title", languageCode: languageCode))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))

            Text(L10n.t("profile_my_teams_empty_body", languageCode: languageCode))
                .font(.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            if let onCreateTeam {
                Button(action: onCreateTeam) {
                    Text(L10n.t("profile_my_teams_create_team", languageCode: languageCode))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            FGColor.intentTeams,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("profile_my_teams_create_team", languageCode: languageCode))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(FGColor.cardBackground(colorScheme))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.7), lineWidth: 1)
        }
    }
}

struct ProfileIdentityMyTeamsRetryView: View {
    let languageCode: String
    var onRetry: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("fan_teams_refresh_failed", languageCode: languageCode))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            if let onRetry {
                Button(action: onRetry) {
                    Text(L10n.t("Try Again", languageCode: languageCode))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            FGColor.intentTeams,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("Try Again", languageCode: languageCode))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(FGColor.cardBackground(colorScheme))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.7), lineWidth: 1)
        }
    }
}

// MARK: - Carousel

struct ProfileMyTeamsCarousel: View {
    let memberships: [ProfileFanTeamMembership]
    let languageCode: String
    let onOpenTeam: ((ProfileFanTeamMembership) -> Void)?

    /// Cached so GeometryReader width probes do not rebuild cards every parent invalidate.
    @State private var cardWidth: CGFloat = ProfileMyTeamsCarouselLayout.minCardWidth
    @State private var displayedMemberships: [ProfileFanTeamMembership] = []
    @State private var artworkTokens: [UUID: UUID] = [:]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: ProfileMyTeamsCarouselLayout.cardSpacing) {
                ForEach(displayedMemberships) { membership in
                    ProfileMyTeamsMembershipCard(
                        membership: membership,
                        languageCode: languageCode,
                        cardWidth: cardWidth,
                        onTap: membership.viewerCanOpen
                            ? { onOpenTeam?(membership) }
                            : nil,
                        displayRefreshToken: artworkTokens[membership.teamId]
                    )
                }
            }
            .padding(.vertical, 2)
            .padding(.trailing, 2)
        }
        .scrollClipDisabled()
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { commitCardWidth(for: geo.size.width) }
                    .onChange(of: geo.size.width) { _, width in
                        commitCardWidth(for: width)
                    }
            }
        }
        .frame(height: ProfileMyTeamsCarouselLayout.cardHeight + 4)
        .onAppear {
            if displayedMemberships.isEmpty {
                displayedMemberships = memberships
            }
        }
        .onChange(of: memberships) { _, next in
            displayedMemberships = next
        }
        .onReceive(NotificationCenter.default.publisher(for: FanTeamIdentityChangeCenter.identityDidChangeNotification)) { note in
            guard let change = FanTeamIdentityChangeCenter.identityChange(from: note) else { return }
            var next = displayedMemberships
            var changed = false
            for index in next.indices where next[index].teamId == change.teamId {
                next[index] = next[index].applyingIdentityChange(change)
                changed = true
            }
            if changed {
                displayedMemberships = next
            }
            if FanTeamArtworkPropagation.artworkChanged(change) {
                artworkTokens[change.teamId] = change.displayRefreshToken
            }
        }
    }

    private func commitCardWidth(for containerWidth: CGFloat) {
        let next = ProfileMyTeamsCarouselLayout.cardWidth(containerWidth: containerWidth)
        guard abs(next - cardWidth) > 0.5 else { return }
        cardWidth = next
    }
}

// MARK: - Own profile section

/// Own-profile My Teams section (always visible to owner; uses list_my_fan_teams).
struct ProfileIdentityMyTeamsSection: View {
    let languageCode: String
    let memberships: [ProfileFanTeamMembership]
    var loadFailed: Bool = false
    let onOpenTeam: (ProfileFanTeamMembership) -> Void
    var onViewAll: (() -> Void)? = nil
    var onCreateTeam: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProfileMyTeamsSectionHeader(
                languageCode: languageCode,
                showsEmptyHint: false,
                onViewAll: memberships.isEmpty ? nil : onViewAll
            )

            if memberships.isEmpty {
                if loadFailed {
                    ProfileIdentityMyTeamsRetryView(
                        languageCode: languageCode,
                        onRetry: onRetry
                    )
                } else {
                    ProfileMyTeamsEmptyStateView(
                        languageCode: languageCode,
                        onCreateTeam: onCreateTeam
                    )
                }
            } else {
                ProfileMyTeamsCarousel(
                    memberships: memberships,
                    languageCode: languageCode,
                    onOpenTeam: onOpenTeam
                )
            }
        }
        .padding(.bottom, 8)
    }
}

// MARK: - Public / preview section

/// Public / self-preview My Teams section (hidden when empty after privacy filter).
struct PublicProfileMyTeamsSection: View {
    let memberships: [ProfileFanTeamMembership]
    let languageCode: String
    let onOpenTeam: ((ProfileFanTeamMembership) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProfileMyTeamsSectionHeader(languageCode: languageCode)

            ProfileMyTeamsCarousel(
                memberships: memberships,
                languageCode: languageCode,
                onOpenTeam: onOpenTeam
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Edit Profile visibility

/// Edit Profile visibility card: current value + horizontal chips mapped to
/// `FanTeamProfileVisibility` (`everyone` / `friends` / `team_members` / `only_me`).
struct EditProfileMyTeamsVisibilityRow: View {
    @Binding var visibility: FanTeamProfileVisibility
    let languageCode: String

    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color { FGColor.intentTeams }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t("profile_my_teams_show_on_profile", languageCode: languageCode))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)

                    Text(L10n.t("profile_my_teams_subtitle", languageCode: languageCode))
                        .font(.footnote)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                visibilityMenu
            }

            visibilityChips

            Text(L10n.t("profile_my_teams_visibility_help", languageCode: languageCode))
                .font(.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, EditProfileSheetLayout.rowHorizontal)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var visibilityMenu: some View {
        Menu {
            Picker(
                L10n.t("profile_my_teams_visibility", languageCode: languageCode),
                selection: $visibility
            ) {
                ForEach(FanTeamProfileVisibility.allCases) { option in
                    Text(option.localizedTitle(languageCode: languageCode))
                        .tag(option)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(visibility.localizedTitle(languageCode: languageCode))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(accent.opacity(colorScheme == .dark ? 0.22 : 0.12), in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("profile_my_teams_visibility", languageCode: languageCode))
        .accessibilityValue(visibility.localizedTitle(languageCode: languageCode))
    }

    private var visibilityChips: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(FanTeamProfileVisibility.allCases) { option in
                visibilityChip(option)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func visibilityChip(_ option: FanTeamProfileVisibility) -> some View {
        let selected = visibility == option
        return Button {
            FGInteractionHaptics.selection()
            visibility = option
        } label: {
            VStack(spacing: 6) {
                Image(systemName: option.editProfileChipSystemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(selected ? accent : FGColor.secondaryText(colorScheme))
                    .frame(height: 20)
                Text(option.localizedTitle(languageCode: languageCode))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(selected ? accent : FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        selected
                            ? accent.opacity(colorScheme == .dark ? 0.22 : 0.12)
                            : (colorScheme == .dark ? Color.white.opacity(0.06) : Color.white)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        selected ? accent.opacity(0.35) : Color.black.opacity(colorScheme == .dark ? 0.18 : 0.08),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.localizedTitle(languageCode: languageCode))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(L10n.t("profile_my_teams_visibility", languageCode: languageCode))
    }
}
