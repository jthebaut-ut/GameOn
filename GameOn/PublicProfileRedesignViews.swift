import SwiftUI

// MARK: - Open To split (sports vs social)

enum PublicProfileOpenToSplit {
    /// Deduped public chips preserving stored order (sports + social).
    static func allItems(from items: [PublicProfileOpenToItem]) -> [PublicProfileOpenToItem] {
        var seen = Set<String>()
        var out: [PublicProfileOpenToItem] = []
        for item in items {
            let canonical = FanOpenToCatalog.canonicalItemID(item.id) ?? item.id
            guard seen.insert(canonical).inserted else { continue }
            if let remapped = FanOpenToCatalog.publicDisplayItems(from: [canonical]).first {
                out.append(remapped)
            } else {
                out.append(PublicProfileOpenToItem(
                    id: canonical,
                    title: item.title,
                    systemImage: item.systemImage,
                    tint: item.tint,
                    isSocial: item.isSocial
                ))
            }
        }
        return out
    }

    static func sportItems(from items: [PublicProfileOpenToItem]) -> [PublicProfileOpenToItem] {
        allItems(from: items).filter { !$0.isSocial }
    }

    static func socialItems(from items: [PublicProfileOpenToItem]) -> [PublicProfileOpenToItem] {
        allItems(from: items).filter(\.isSocial)
    }
}

// MARK: - Identity copy

enum PublicProfileIdentityCopy {
    static func heroIdentityLine(for data: PublicUserProfileData, languageCode: String) -> String {
        let location = data.homeCityDisplayLine?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fanNoun = L10n.t("public_profile_identity_fan", languageCode: languageCode)
        let supporterNoun = L10n.t("public_profile_identity_supporter", languageCode: languageCode)

        var identity: String?
        if let national = data.nationalTeam {
            let country = national.countryName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !country.isEmpty {
                let flag = national.flag.trimmingCharacters(in: .whitespacesAndNewlines)
                let core = "\(country) \(supporterNoun)"
                identity = flag.isEmpty ? core : "\(flag) \(core)"
            }
        } else if let team = data.primaryFavoriteTeam {
            identity = "\(team.name) \(fanNoun)"
        } else if let sport = PublicProfileOpenToSplit.sportItems(from: data.openToItems).first {
            identity = "\(sport.title) \(fanNoun)"
        }

        let resolved = identity ?? L10n.t("public_profile_identity_sports_fan", languageCode: languageCode)
        if !location.isEmpty {
            return "\(resolved) • \(location)"
        }
        if identity == nil, let year = FanGeoHandleRules.fanSinceYear(from: data.profileCreatedAt) {
            return String(
                format: L10n.t("public_profile_member_since_year_format", languageCode: languageCode),
                year
            )
        }
        return resolved
    }
}

// MARK: - Hero background

enum PublicProfileHeroBackgroundKind: Equatable {
    case team(FavoriteTeam)
    case sport(String)
    case neutral
}

enum PublicProfileHeroBackgroundResolver {
    static func resolve(for data: PublicUserProfileData) -> PublicProfileHeroBackgroundKind {
        if let primary = data.primaryFavoriteTeam {
            return .team(primary)
        }
        if let first = data.orderedFavoriteTeamsForPublicProfile.first {
            return .team(first)
        }
        if let sport = PublicProfileOpenToSplit.sportItems(from: data.openToItems).first {
            return .sport(sport.id)
        }
        return .neutral
    }
}

struct PublicProfileHeroBackgroundView: View {
    let kind: PublicProfileHeroBackgroundKind
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            softBase
            accentLayer
            subtleStadiumOverlay
            bottomFade
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var softBase: some View {
        LinearGradient(
            colors: [
                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.22 : 0.16),
                FGColor.accentGreen.opacity(colorScheme == .dark ? 0.12 : 0.08),
                Color.white.opacity(colorScheme == .dark ? 0.03 : 0.82)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    @ViewBuilder
    private var accentLayer: some View {
        switch kind {
        case .team(let team):
            if team.kind == .nationalTeam {
                nationalTreatment(team)
            } else {
                clubTreatment(team)
            }
        case .sport(let token):
            sportTreatment(token)
        case .neutral:
            EmptyView()
        }
    }

    private func clubTreatment(_ team: FavoriteTeam) -> some View {
        LinearGradient(
            colors: [
                team.badgeColor.opacity(colorScheme == .dark ? 0.30 : 0.20),
                team.badgeColor.opacity(colorScheme == .dark ? 0.08 : 0.05),
                Color.clear
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func nationalTreatment(_ team: FavoriteTeam) -> some View {
        // Soft flag-inspired wash: primary · light · companion — never a literal flag.
        LinearGradient(
            colors: [
                team.badgeColor.opacity(colorScheme == .dark ? 0.34 : 0.26),
                Color.white.opacity(colorScheme == .dark ? 0.12 : 0.72),
                nationalCompanion(for: team).opacity(colorScheme == .dark ? 0.24 : 0.20)
            ],
            startPoint: .topLeading,
            endPoint: .topTrailing
        )
        .opacity(0.78)
    }

    private func nationalCompanion(for team: FavoriteTeam) -> Color {
        // Prefer a warm companion when the badge is cool (e.g. France blue → soft red).
        let r = team.badgeRed
        let b = team.badgeBlue
        if b > r + 0.12 {
            return Color(red: 0.82, green: 0.18, blue: 0.22)
        }
        if r > b + 0.12 {
            return Color(red: 0.12, green: 0.28, blue: 0.68)
        }
        return team.badgeColor
    }

    private func sportTreatment(_ token: String) -> some View {
        let accent = SportFilterCatalog.resolve(token).accent
        return accent.opacity(colorScheme == .dark ? 0.14 : 0.09)
    }

    private var subtleStadiumOverlay: some View {
        // Soft seating arc suggestion — very low contrast.
        LinearGradient(
            colors: [
                Color.clear,
                Color.black.opacity(colorScheme == .dark ? 0.05 : 0.02)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .mask {
            Ellipse()
                .frame(width: 480, height: 140)
                .offset(y: 40)
                .blur(radius: 28)
        }
    }

    private var bottomFade: some View {
        LinearGradient(
            colors: [
                Color.clear,
                (colorScheme == .dark ? Color.black : Color.white).opacity(0.72)
            ],
            startPoint: .center,
            endPoint: .bottom
        )
    }
}

// MARK: - Compact surface chrome

private struct PublicProfileCompactSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat = 16
    var elevated: Bool = true

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.98))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.40 : 0.42), lineWidth: 1)
            }
            .shadow(
                color: Color.black.opacity(elevated ? (colorScheme == .dark ? 0.14 : 0.03) : 0),
                radius: elevated ? 6 : 0,
                y: elevated ? 2 : 0
            )
    }
}

extension View {
    fileprivate func publicProfileCompactSurface(cornerRadius: CGFloat = 16, elevated: Bool = true) -> some View {
        modifier(PublicProfileCompactSurface(cornerRadius: cornerRadius, elevated: elevated))
    }
}

// MARK: - Owner preview notice

struct PublicProfileOwnerPreviewNotice: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .accessibilityHidden(true)
            Text(L10n.t("public_profile_previewing_notice", languageCode: appLanguageRaw))
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.12 : 0.06))
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Redesigned hero

struct PublicProfileRedesignHero: View {
    let data: PublicUserProfileData
    let isSelfPreview: Bool
    let friendState: PublicProfileFriendButtonState
    let isFriendActionInFlight: Bool
    let canShowSafetyActions: Bool
    let canPoke: Bool
    let pokeTitle: String
    let isPokeDisabled: Bool
    let isPokeInFlight: Bool
    let onAddFriend: () -> Void
    let onCancelRequest: () -> Void
    let onMessage: () -> Void
    let onEditProfile: () -> Void
    let onShare: () -> Void
    let onReport: () -> Void
    let onBlock: () -> Void
    let onPoke: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @State private var containerWidth: CGFloat = 0

    private var backgroundKind: PublicProfileHeroBackgroundKind {
        PublicProfileHeroBackgroundResolver.resolve(for: data)
    }

    private var avatarDiameter: CGFloat {
        guard containerWidth > 0 else { return 84 }
        return min(88, max(76, containerWidth * 0.215))
    }

    private var trimmedBio: String {
        data.bio?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var identityLine: String {
        PublicProfileIdentityCopy.heroIdentityLine(for: data, languageCode: appLanguageRaw)
    }

    private var handleOnly: String {
        data.publicHandleLine.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                PublicProfileHeroBackgroundView(kind: backgroundKind)
                    .frame(height: 86)
                    .frame(maxWidth: .infinity)

                Color.clear.frame(height: 1)
            }
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 16,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 16,
                    style: .continuous
                )
            )

            HStack(alignment: .center, spacing: 12) {
                avatar
                    .offset(y: -avatarDiameter * 0.42)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(data.displayName)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)

                        if data.reputation.privileges.isVerifiedOrganizer {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(FGColor.accentBlue)
                                .accessibilityLabel(L10n.t("public_profile_verified_organizer_a11y", languageCode: appLanguageRaw))
                        }
                    }

                    if !handleOnly.isEmpty {
                        Text(handleOnly.hasPrefix("@") ? handleOnly : "@\(handleOnly)")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(FGColor.secondaryText(colorScheme).opacity(0.88))
                    }

                    Text(identityLine)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme).opacity(0.95))
                        .lineLimit(2)

                    if !trimmedBio.isEmpty {
                        Text(trimmedBio)
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            .foregroundStyle(FGColor.mutedText(colorScheme))
                            .lineSpacing(1)
                            .lineLimit(3)
                    } else if isSelfPreview {
                        Text(L10n.t("public_profile_owner_add_bio_prompt", languageCode: appLanguageRaw))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                }
                // Raise identity to sit beside the avatar center, matching the mock.
                .offset(y: -avatarDiameter * 0.10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)

            PublicProfileHeroActionRow(
                isSelfPreview: isSelfPreview,
                friendState: friendState,
                isFriendActionInFlight: isFriendActionInFlight,
                canShowSafetyActions: canShowSafetyActions,
                canPoke: canPoke,
                pokeTitle: pokeTitle,
                isPokeDisabled: isPokeDisabled,
                isPokeInFlight: isPokeInFlight,
                displayName: data.displayName,
                onAddFriend: onAddFriend,
                onCancelRequest: onCancelRequest,
                onMessage: onMessage,
                onEditProfile: onEditProfile,
                onShare: onShare,
                onReport: onReport,
                onBlock: onBlock,
                onPoke: onPoke
            )
            .padding(.horizontal, 14)
            .padding(.top, 14)

            // Shared-teams context only (mutual friends live in the dedicated section below).
            if !isSelfPreview, data.sharedTeamsCount > 0 {
                PublicProfileSocialContextRow(
                    mutualCount: 0,
                    mutualAvatars: [],
                    sharedTeamsCount: data.sharedTeamsCount,
                    sharedTeamNames: data.sharedTeamNames
                )
                .padding(.horizontal, 14)
                .padding(.top, 12)
            }
        }
        .padding(.bottom, 18)
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: PublicProfileRedesignHeroWidthKey.self, value: geo.size.width)
            }
        }
        .onPreferenceChange(PublicProfileRedesignHeroWidthKey.self) { containerWidth = $0 }
        .publicProfileCompactSurface(cornerRadius: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(heroAccessibilityLabel)
    }

    private var heroAccessibilityLabel: String {
        var parts = [data.displayName]
        if !handleOnly.isEmpty {
            parts.append(handleOnly.hasPrefix("@") ? handleOnly : "@\(handleOnly)")
        }
        parts.append(identityLine)
        if !trimmedBio.isEmpty {
            parts.append(trimmedBio)
        }
        return parts.joined(separator: ". ")
    }

    private var avatar: some View {
        UserAvatarView(
            avatarThumbnailURL: data.avatarThumbnailURL,
            avatarURL: data.avatarURL ?? "",
            avatarDisplayRefreshToken: UserAvatarView.stableRefreshToken(
                userId: data.userId,
                thumbnailURL: data.avatarThumbnailURL,
                avatarURL: data.avatarURL
            ),
            displayName: data.displayName,
            email: "",
            size: avatarDiameter,
            fallbackStyle: .lightOnWhiteChrome,
            imagePlaceholderTint: FGColor.accentBlue
        )
        .overlay {
            Circle()
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.40 : 1), lineWidth: 2.5)
        }
        .shadow(color: Color.black.opacity(0.10), radius: 6, y: 2)
    }
}

private struct PublicProfileRedesignHeroWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Hero actions

struct PublicProfileHeroActionRow: View {
    let isSelfPreview: Bool
    let friendState: PublicProfileFriendButtonState
    let isFriendActionInFlight: Bool
    let canShowSafetyActions: Bool
    let canPoke: Bool
    let pokeTitle: String
    let isPokeDisabled: Bool
    let isPokeInFlight: Bool
    var displayName: String = ""
    let onAddFriend: () -> Void
    let onCancelRequest: () -> Void
    let onMessage: () -> Void
    let onEditProfile: () -> Void
    let onShare: () -> Void
    let onReport: () -> Void
    let onBlock: () -> Void
    let onPoke: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var canMessage: Bool {
        friendState == .messageFriend
    }

    var body: some View {
        HStack(spacing: 10) {
            if isSelfPreview {
                primaryButton(
                    title: L10n.t("edit_profile", languageCode: appLanguageRaw),
                    icon: "pencil",
                    filled: true,
                    action: onEditProfile
                )
                secondaryButton(
                    title: L10n.t("share_profile", languageCode: appLanguageRaw),
                    icon: "square.and.arrow.up",
                    action: onShare
                )
                moreMenu
            } else {
                friendshipAction
                messageAction
                if canPoke {
                    pokeAction
                }
                moreMenu
            }
        }
    }

    @ViewBuilder
    private var friendshipAction: some View {
        switch friendState {
        case .requestFriendship:
            primaryButton(
                title: L10n.t("add_friend", languageCode: appLanguageRaw),
                icon: "person.badge.plus",
                filled: true,
                disabled: isFriendActionInFlight,
                action: onAddFriend
            )
        case .friendshipRequested:
            secondaryButton(
                title: L10n.t("request_sent", languageCode: appLanguageRaw),
                icon: "clock",
                disabled: isFriendActionInFlight,
                action: onCancelRequest
            )
        case .messageFriend:
            secondaryButton(
                title: L10n.t("friends", languageCode: appLanguageRaw),
                icon: "person.2.fill",
                disabled: true,
                action: {}
            )
        case .hidden:
            EmptyView()
        }
    }

    private var messageAction: some View {
        primaryButton(
            title: L10n.t("message", languageCode: appLanguageRaw),
            icon: "message.fill",
            filled: canMessage,
            disabled: !canMessage || isFriendActionInFlight,
            action: onMessage
        )
        .opacity(canMessage ? 1 : 0.55)
        .accessibilityHint(
            canMessage
                ? ""
                : L10n.t("public_profile_message_friends_only_a11y", languageCode: appLanguageRaw)
        )
    }

    private var pokeAction: some View {
        Button(action: onPoke) {
            HStack(spacing: 5) {
                if isPokeInFlight {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "hand.wave.fill")
                        .font(.system(size: 12, weight: .bold))
                }
                Text(pokeTitle)
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .foregroundStyle(FGColor.accentBlue)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.12 : 1))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(FGColor.accentBlue.opacity(0.55), lineWidth: 1.2)
            }
        }
        .buttonStyle(.plain)
        .disabled(isPokeDisabled || isPokeInFlight)
        .opacity(isPokeDisabled ? 0.65 : 1)
        .accessibilityLabel(
            String(
                format: L10n.t("public_profile_poke_a11y_format", languageCode: appLanguageRaw),
                displayName
            )
        )
    }

    private var moreMenu: some View {
        Menu {
            if isSelfPreview {
                Button {
                    onShare()
                } label: {
                    Label(L10n.t("share_profile", languageCode: appLanguageRaw), systemImage: "square.and.arrow.up")
                }
            } else {
                Button {
                    onShare()
                } label: {
                    Label(L10n.t("share_profile", languageCode: appLanguageRaw), systemImage: "square.and.arrow.up")
                }

                if friendState == .friendshipRequested {
                    Button(role: .destructive) {
                        onCancelRequest()
                    } label: {
                        Label(L10n.t("cancel_friend_request", languageCode: appLanguageRaw), systemImage: "person.badge.minus")
                    }
                }

                // Poke is a dedicated hero button; keep menu free of the duplicate.

                if canShowSafetyActions {
                    Button {
                        onReport()
                    } label: {
                        Label(L10n.t("report_fan", languageCode: appLanguageRaw), systemImage: "flag.fill")
                    }

                    Button(role: .destructive) {
                        onBlock()
                    } label: {
                        Label(L10n.t("block_fan", languageCode: appLanguageRaw), systemImage: "nosign")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(FGColor.accentBlue)
                .frame(width: 38, height: 38)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.12 : 1))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(FGColor.accentBlue.opacity(0.55), lineWidth: 1.2)
                }
        }
        .accessibilityLabel(
            displayName.isEmpty
                ? L10n.t("public_profile_more_options_a11y", languageCode: appLanguageRaw)
                : String(
                    format: L10n.t("public_profile_more_actions_a11y_format", languageCode: appLanguageRaw),
                    displayName
                )
        )
    }

    private func primaryButton(
        title: String,
        icon: String,
        filled: Bool,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                Text(title)
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .foregroundStyle(filled ? Color.white : FGColor.accentBlue)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(filled ? FGColor.accentBlue : FGColor.accentBlue.opacity(colorScheme == .dark ? 0.16 : 0.10))
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled && friendState != .messageFriend ? 0.7 : 1)
    }

    private func secondaryButton(
        title: String,
        icon: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                Text(title)
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .foregroundStyle(FGColor.accentBlue)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.12 : 1))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(FGColor.accentBlue.opacity(0.55), lineWidth: 1.2)
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled && title == L10n.t("friends", languageCode: appLanguageRaw) ? 1 : (disabled ? 0.7 : 1))
    }
}

// MARK: - Mutual / shared context under hero

struct PublicProfileSocialContextRow: View {
    let mutualCount: Int
    let mutualAvatars: [PublicProfileMutualFanAvatar]
    let sharedTeamsCount: Int
    let sharedTeamNames: [String]
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var hasContent: Bool {
        mutualCount > 0 || sharedTeamsCount > 0
    }

    var body: some View {
        if !hasContent {
            EmptyView()
        } else {
            HStack(spacing: 8) {
                if mutualCount > 0 {
                    HStack(spacing: -7) {
                        ForEach(uniquedMutualAvatars(Array(mutualAvatars.prefix(3)))) { fan in
                            UserAvatarView(
                                avatarThumbnailURL: fan.avatarURL,
                                avatarURL: fan.avatarURL ?? "",
                                avatarDisplayRefreshToken: UserAvatarView.stableRefreshToken(
                                    userId: fan.userId,
                                    thumbnailURL: fan.avatarURL,
                                    avatarURL: fan.avatarURL
                                ),
                                displayName: fan.displayName,
                                email: "",
                                size: 22,
                                fallbackStyle: .lightOnWhiteChrome,
                                imagePlaceholderTint: FGColor.accentBlue
                            )
                            .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.25))
                        }
                        if mutualCount > 3 {
                            Text("+\(mutualCount - 3)")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.white)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(FGColor.accentBlue))
                        }
                    }
                    .accessibilityHidden(true)
                }

                contextText
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.08 : 0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme).opacity(0.55), lineWidth: 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(contextLabel)
        }
    }

    private var contextText: Text {
        let mutualSegment: Text? = {
            guard mutualCount > 0 else { return nil }
            let mutual = PublicProfileMutualFriendsFormatting.countLabel(
                count: mutualCount,
                languageCode: appLanguageRaw
            )
            return Text(mutual)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(FGColor.accentBlue)
        }()

        let sharedSegment: Text? = {
            guard sharedTeamsCount > 0 else { return nil }
            let shared = PublicProfileMutualFriendsFormatting.sharedTeamsLabel(
                count: sharedTeamsCount,
                languageCode: appLanguageRaw
            )
            return Text(shared)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(FGColor.accentBlue)
        }()

        switch (mutualSegment, sharedSegment) {
        case let (mutual?, shared?):
            let separator = Text(" · ")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(FGColor.secondaryText(colorScheme))
            return Text("\(mutual)\(separator)\(shared)")
        case let (mutual?, nil):
            return mutual
        case let (nil, shared?):
            return shared
        case (nil, nil):
            return Text("")
        }
    }

    private var contextLabel: String {
        var parts: [String] = []
        if mutualCount > 0 {
            parts.append(
                PublicProfileMutualFriendsFormatting.countLabel(
                    count: mutualCount,
                    languageCode: appLanguageRaw
                )
            )
        }
        if sharedTeamsCount > 0 {
            parts.append(
                PublicProfileMutualFriendsFormatting.sharedTeamsLabel(
                    count: sharedTeamsCount,
                    languageCode: appLanguageRaw
                )
            )
        }
        return parts.joined(separator: " · ")
    }

    private func uniquedMutualAvatars(
        _ input: [PublicProfileMutualFanAvatar]
    ) -> [PublicProfileMutualFanAvatar] {
        var seen = Set<UUID>()
        var out: [PublicProfileMutualFanAvatar] = []
        out.reserveCapacity(input.count)
        for avatar in input {
            guard seen.insert(avatar.userId).inserted else { continue }
            out.append(avatar)
        }
        return out
    }
}

// MARK: - Fan snapshot (simplified)

struct PublicProfileFanSnapshotView: View {
    let data: PublicUserProfileData
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private struct Column: Identifiable {
        let id: String
        let icon: String
        let iconIsEmoji: Bool
        let title: String
        let subtitle: String
    }

    private var columns: [Column] {
        var result: [Column] = []
        if let identity = data.nationalTeam {
            let flag = identity.flag.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(
                Column(
                    id: "national",
                    icon: flag.isEmpty ? "flag.fill" : flag,
                    iconIsEmoji: !flag.isEmpty,
                    title: identity.resolvedSupporterLabel(languageCode: appLanguageRaw),
                    subtitle: NationalTeamCopy.text("world_cup_2026", languageCode: appLanguageRaw)
                )
            )
        } else if let team = data.primaryFavoriteTeam {
            result.append(
                Column(
                    id: "team",
                    icon: "star.fill",
                    iconIsEmoji: false,
                    title: "\(team.name) \(L10n.t("public_profile_identity_fan", languageCode: appLanguageRaw))",
                    subtitle: L10n.t("my_team", languageCode: appLanguageRaw)
                )
            )
        }
        if let city = data.homeCityDisplayLine?.trimmingCharacters(in: .whitespacesAndNewlines), !city.isEmpty {
            result.append(
                Column(
                    id: "city",
                    icon: "mappin.and.ellipse",
                    iconIsEmoji: false,
                    title: city,
                    subtitle: L10n.t("public_profile_home_city", languageCode: appLanguageRaw)
                )
            )
        }
        if let since = FanGeoHandleRules.fanSinceMonthYear(from: data.profileCreatedAt) {
            result.append(
                Column(
                    id: "since",
                    icon: "calendar",
                    iconIsEmoji: false,
                    title: since,
                    subtitle: L10n.t("public_profile_member_since", languageCode: appLanguageRaw)
                )
            )
        }
        return result
    }

    var body: some View {
        if columns.isEmpty {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 8) {
                ForEach(columns) { column in
                    VStack(spacing: 5) {
                        Group {
                            if column.iconIsEmoji {
                                Text(column.icon)
                                    .font(.system(size: 16))
                            } else {
                                Image(systemName: column.icon)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(FGColor.accentBlue)
                            }
                        }
                        .frame(height: 18)

                        Text(column.title)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.78)

                        Text(column.subtitle)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 10)
                    .publicProfileCompactSurface(cornerRadius: 14, elevated: false)
                }
            }
        }
    }
}

// MARK: - Teams I Follow

struct PublicProfileTeamsIFollowSection: View {
    let data: PublicUserProfileData
    let isSelfPreview: Bool
    let onChooseTeam: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @State private var containerWidth: CGFloat = 0

    private var teams: [FavoriteTeam] {
        data.orderedFavoriteTeamsForPublicProfile
    }

    /// Target ~2.55 cards visible so the carousel peeks clearly.
    private var cardWidth: CGFloat {
        let usable = max(containerWidth - 24, 280)
        return min(168, max(136, usable / 2.55))
    }

    var body: some View {
        if teams.isEmpty {
            if isSelfPreview {
                PublicProfileOwnerCompletionPrompt(
                    title: L10n.t("public_profile_build_fan_identity", languageCode: appLanguageRaw),
                    subtitle: L10n.t("public_profile_choose_team_supporting", languageCode: appLanguageRaw),
                    actionTitle: L10n.t("public_profile_choose_a_team", languageCode: appLanguageRaw),
                    action: onChooseTeam
                )
            } else {
                EmptyView()
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(L10n.t("teams_i_follow", languageCode: appLanguageRaw)) · \(teams.count)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .center, spacing: 8) {
                        ForEach(teams) { team in
                            teamCard(team, isPrimary: team.id == data.primaryFavoriteTeam?.id)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.trailing, 20)
                }
                .scrollTargetBehavior(.viewAligned)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { geo in
                    Color.clear.preference(key: PublicProfileTeamsWidthKey.self, value: geo.size.width)
                }
            }
            .onPreferenceChange(PublicProfileTeamsWidthKey.self) { containerWidth = $0 }
            .publicProfileCompactSurface(cornerRadius: 16)
        }
    }

    private func teamCard(_ team: FavoriteTeam, isPrimary: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            SportsIdentityArtworkView(favoriteTeam: team, diameter: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(team.name)
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)

                HStack(spacing: 4) {
                    Text(sportIcon(for: team.sport.chipTitle))
                        .font(.system(size: 10))
                    Text(team.sport.chipTitle)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }

                if isPrimary {
                    Text(L10n.t("my_team", languageCode: appLanguageRaw))
                        .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                        .foregroundStyle(FGColor.accentBlue)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background {
                            Capsule().fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.18 : 0.10))
                        }
                        .padding(.top, 1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(width: cardWidth, height: 88, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.96))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isPrimary ? FGColor.accentBlue.opacity(0.55) : FGColor.divider(colorScheme).opacity(0.7),
                    lineWidth: isPrimary ? 1.4 : 1
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            isPrimary
                ? "\(team.name), \(team.sport.chipTitle). \(L10n.t("my_team", languageCode: appLanguageRaw))"
                : "\(team.name), \(team.sport.chipTitle)"
        )
    }
}

private struct PublicProfileTeamsWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Sports I Play

struct PublicProfileSportsIPlaySection: View {
    let items: [PublicProfileOpenToItem]
    let isSelfPreview: Bool
    let onAddSports: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    var body: some View {
        if items.isEmpty {
            if isSelfPreview {
                PublicProfileOwnerCompletionPrompt(
                    title: L10n.t("public_profile_add_sports_you_play", languageCode: appLanguageRaw),
                    subtitle: nil,
                    actionTitle: nil,
                    action: onAddSports
                )
            } else {
                EmptyView()
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("sports_i_play", languageCode: appLanguageRaw))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(items) { item in
                            HStack(spacing: 6) {
                                FanGeoSportBadgeView(sport: item.id, size: 18, style: .profile)
                                Text(item.openToGridLabel)
                                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                                    .foregroundStyle(FGColor.primaryText(colorScheme))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .background {
                                Capsule(style: .continuous)
                                    .fill(FanOpenToCatalog.compactTileFill(for: item.id, colorScheme: colorScheme))
                            }
                            .overlay {
                                Capsule(style: .continuous)
                                    .strokeBorder(FGColor.divider(colorScheme).opacity(0.45), lineWidth: 1)
                            }
                            .accessibilityLabel(item.openToGridLabel)
                        }
                    }
                    .padding(.trailing, 4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .publicProfileCompactSurface(cornerRadius: 16)
        }
    }
}

// MARK: - Social Open To (compact)

struct PublicProfileSocialOpenToSection: View {
    let items: [PublicProfileOpenToItem]
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    var body: some View {
        if items.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("open_to", languageCode: appLanguageRaw))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(items) { item in
                            HStack(spacing: 6) {
                                Image(systemName: item.systemImage)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(item.tint)
                                Text(item.openToGridLabel)
                                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                                    .foregroundStyle(FGColor.primaryText(colorScheme))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .background {
                                Capsule(style: .continuous)
                                    .fill(FanOpenToCatalog.compactTileFill(for: item.id, colorScheme: colorScheme))
                            }
                            .accessibilityLabel(item.openToGridLabel)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .publicProfileCompactSurface(cornerRadius: 16)
        }
    }
}

// MARK: - Home Watch Spot

struct PublicProfileHomeWatchSpotSection: View {
    let summary: HomeCrowdVenueSummary?
    let isSelfPreview: Bool
    let onViewSpot: (() -> Void)?
    let onChooseSpot: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private let imageSide: CGFloat = 86
    private var accent: Color { HomeCrowdCardStyle.accent }

    var body: some View {
        if let summary {
            populatedCard(summary)
        } else if isSelfPreview {
            PublicProfileOwnerCompletionPrompt(
                title: L10n.t("public_profile_choose_home_watch_spot", languageCode: appLanguageRaw),
                subtitle: nil,
                actionTitle: L10n.t("public_profile_choose_home_watch_spot", languageCode: appLanguageRaw),
                action: onChooseSpot
            )
        } else {
            EmptyView()
        }
    }

    private func populatedCard(_ summary: HomeCrowdVenueSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("home_watch_spot", languageCode: appLanguageRaw))
                .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                .foregroundStyle(accent)
                .textCase(.uppercase)
                .tracking(1.08)

            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(summary.name)
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)

                    if !summary.locationLabel.isEmpty {
                        Text(summary.locationLabel)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                    }

                    if summary.fanCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "person.2.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .accessibilityHidden(true)
                            Text("\(summary.fanCount)")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                venuePhoto(summary)
                    .frame(width: imageSide, height: imageSide)
                    .layoutPriority(0)
            }

            viewSpotButton
        }
        .padding(.top, 14)
        .padding(.bottom, 12)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .homeCrowdCardChrome(colorScheme: colorScheme, accent: accent)
        .overlay(alignment: .top) {
            Capsule(style: .continuous)
                .fill(accent.opacity(colorScheme == .dark ? 0.90 : 0.82))
                .frame(height: 3)
                .padding(.horizontal, 18)
                .padding(.top, 1)
                .allowsHitTesting(false)
        }
    }

    private var viewSpotButton: some View {
        Button {
            onViewSpot?()
        } label: {
            HStack(spacing: 5) {
                Text(L10n.t("view_spot", languageCode: appLanguageRaw))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(accent)
            .frame(maxWidth: .infinity, minHeight: 32)
            .padding(.horizontal, 12)
            .background {
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .background {
                        Capsule(style: .continuous)
                            .fill(accent.opacity(colorScheme == .dark ? 0.14 : 0.10))
                    }
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(accent.opacity(0.42), lineWidth: 0.9)
            }
        }
        .buttonStyle(.plain)
        .disabled(onViewSpot == nil)
        .accessibilityLabel(L10n.t("view_spot", languageCode: appLanguageRaw))
    }

    @ViewBuilder
    private func venuePhoto(_ summary: HomeCrowdVenueSummary) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let raw = summary.thumbnailURL, let url = URL(string: raw) {
                    DiscoverCachedRemoteImage(url: url, contentMode: .fill) {
                        placeholder
                    }
                    .id(summary.venueId)
                } else {
                    placeholder
                }
            }
            .frame(width: imageSide, height: imageSide)
            .clipShape(RoundedRectangle(cornerRadius: HomeCrowdCardStyle.imageCornerRadius, style: .continuous))

            LinearGradient(
                colors: [
                    Color.black.opacity(0.02),
                    Color.black.opacity(0.18),
                    Color.black.opacity(0.40)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: HomeCrowdCardStyle.imageCornerRadius, style: .continuous))
            .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: HomeCrowdCardStyle.imageCornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.34 : 0.82),
                            accent.opacity(0.34)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.2
                )

            HomeCrowdShieldStarBadge(diameter: 24, visualState: .active)
                .padding(7)
                .allowsHitTesting(false)
        }
        .shadow(color: accent.opacity(colorScheme == .dark ? 0.28 : 0.16), radius: 12, y: 4)
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.62, green: 0.38, blue: 0.96),
                    Color(red: 0.34, green: 0.42, blue: 0.94),
                    Color(red: 0.18, green: 0.28, blue: 0.72)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            HomeCrowdShieldStarBadge(diameter: 40, visualState: .active)
                .shadow(color: accent.opacity(0.35), radius: 8, y: 3)
        }
    }
}

// MARK: - Mutual Friends section

enum PublicProfileMutualFriendsFormatting {
    /// Accessibility label for the overflow “+N / More” chip. Uses `%lld` Int contract.
    static func overflowAccessibilityLabel(remaining: Int, languageCode: String) -> String {
        guard remaining > 0 else { return "" }
        let key = remaining == 1
            ? "public_profile_more_mutual_friend_a11y_format"
            : "public_profile_more_mutual_friends_a11y_format"
        return String(
            format: L10n.t(key, languageCode: languageCode),
            locale: Locale(identifier: L10n.normalizedLanguageCode(languageCode)),
            Int64(remaining)
        )
    }

    static func countLabel(count: Int, languageCode: String) -> String {
        if count == 1 {
            return L10n.t("public_profile_mutual_fan_one", languageCode: languageCode)
        }
        return String(
            format: L10n.t("public_profile_mutual_fans_other", languageCode: languageCode),
            locale: Locale(identifier: L10n.normalizedLanguageCode(languageCode)),
            Int64(count)
        )
    }

    static func sharedTeamsLabel(count: Int, languageCode: String) -> String {
        if count == 1 {
            return L10n.t("public_profile_shared_team_one", languageCode: languageCode)
        }
        return String(
            format: L10n.t("public_profile_shared_teams_other", languageCode: languageCode),
            locale: Locale(identifier: L10n.normalizedLanguageCode(languageCode)),
            Int64(count)
        )
    }
}

struct PublicProfileMutualFansSection: View {
    let count: Int
    let avatars: [PublicProfileMutualFanAvatar]
    let isSelfPreview: Bool
    /// Profile being viewed (DEBUG logging only).
    var targetUserId: UUID? = nil
    var onSelectFan: ((UUID) -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    /// Compact horizontal strip: show up to 3 identities, then `+N More`.
    private var previewLimit: Int { 3 }

    private var uniquedPayloadAvatars: [PublicProfileMutualFanAvatar] {
        uniquedAvatars(avatars)
    }

    private var visibleAvatars: [PublicProfileMutualFanAvatar] {
        Array(uniquedPayloadAvatars.prefix(previewLimit))
    }

    private var overflowCount: Int {
        max(0, count - visibleAvatars.count)
    }

    var body: some View {
        Group {
            if isSelfPreview && count <= 0 {
                ownerEmptyCard
            } else if !isSelfPreview && count <= 0 {
                visitorEmptyCard
            } else if count > 0 {
                populatedCard
            } else {
                EmptyView()
            }
        }
        .onAppear {
            logMutualFriendsPresentation()
        }
    }

    private func logMutualFriendsPresentation() {
#if DEBUG
        let payloadCount = avatars.count
        let dedupedCount = uniquedPayloadAvatars.count
        let visibleCount = visibleAvatars.count
        let overflow = overflowCount
        let target = targetUserId?.uuidString.lowercased() ?? "nil"
        print(
            "[PublicProfileMutualFriends] targetUserId=\(target) totalCount=\(count) payloadIdentityCount=\(payloadCount) decodedCount=\(payloadCount) dedupedCount=\(dedupedCount) privacyFilteredCount=n/a_server visibleCount=\(visibleCount) overflowCount=\(overflow)"
        )
        if count > 0, visibleCount == 0 {
            print(
                "[PublicProfileMutualFriends] identityOmitted reason=payload_empty_or_privacy_filtered totalCount=\(count) payloadIdentityCount=\(payloadCount)"
            )
        } else if count > dedupedCount, dedupedCount > 0 {
            print(
                "[PublicProfileMutualFriends] identityOmitted reason=count_exceeds_safe_identities totalCount=\(count) safeIdentities=\(dedupedCount)"
            )
        }
#endif
    }

    private var ownerEmptyCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.2")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FGColor.accentBlue)
                .frame(width: 28, height: 28)
                .background {
                    Circle()
                        .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.18 : 0.10))
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("mutual_friends", languageCode: languageCode))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text(L10n.t("public_profile_no_mutual_friends_yet", languageCode: languageCode))
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .publicProfileCompactSurface(cornerRadius: 16)
    }

    private var visitorEmptyCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.2")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .accessibilityHidden(true)

            Text(L10n.t("public_profile_no_mutual_friends_yet", languageCode: languageCode))
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.center)

            Text(L10n.t("public_profile_no_mutual_friends_subtitle", languageCode: languageCode))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .publicProfileCompactSurface(cornerRadius: 16)
        .accessibilityElement(children: .combine)
    }

    private var populatedCard: some View {
        let visible = visibleAvatars
        let remaining = overflowCount

        return VStack(alignment: .leading, spacing: 10) {
            Text("\(L10n.t("mutual_friends", languageCode: languageCode)) · \(count)")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(visible) { fan in
                        Button {
                            onSelectFan?(fan.userId)
                        } label: {
                            VStack(spacing: 5) {
                                UserAvatarView(
                                    avatarThumbnailURL: fan.avatarURL,
                                    avatarURL: fan.avatarURL ?? "",
                                    avatarDisplayRefreshToken: UserAvatarView.stableRefreshToken(
                                        userId: fan.userId,
                                        thumbnailURL: fan.avatarURL,
                                        avatarURL: fan.avatarURL
                                    ),
                                    displayName: fan.displayName,
                                    email: "",
                                    size: 52,
                                    fallbackStyle: .lightOnWhiteChrome,
                                    imagePlaceholderTint: FGColor.accentBlue
                                )
                                Text(fan.displayName)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.72)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 64)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(onSelectFan == nil)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            "\(fan.displayName), \(L10n.t("public_profile_mutual_friend_a11y_role", languageCode: languageCode))"
                        )
                        .accessibilityHint(L10n.t("public_profile_open_mutual_friend_hint", languageCode: languageCode))
                    }

                    // Overflow only for identities beyond the visible strip — never replace the
                    // only available mutual friend with a lone "+1 More" when their row exists.
                    if remaining > 0 {
                        VStack(spacing: 5) {
                            Text("+\(remaining)")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(FGColor.accentBlue)
                                .frame(width: 52, height: 52)
                                .background {
                                    Circle()
                                        .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.18 : 0.10))
                                }
                            Text(L10n.t("public_profile_more", languageCode: languageCode))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .lineLimit(1)
                                .frame(width: 64)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            PublicProfileMutualFriendsFormatting.overflowAccessibilityLabel(
                                remaining: remaining,
                                languageCode: languageCode
                            )
                        )
                        // No dedicated full-list destination yet — preview only.
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .publicProfileCompactSurface(cornerRadius: 16)
    }

    private func uniquedAvatars(_ input: [PublicProfileMutualFanAvatar]) -> [PublicProfileMutualFanAvatar] {
        var seen = Set<UUID>()
        var out: [PublicProfileMutualFanAvatar] = []
        out.reserveCapacity(input.count)
        for avatar in input {
            guard seen.insert(avatar.userId).inserted else { continue }
            out.append(avatar)
        }
        return out
    }
}

// MARK: - Owner completion prompt

struct PublicProfileOwnerCompletionPrompt: View {
    let title: String
    let subtitle: String?
    let actionTitle: String?
    let action: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.accentGreen)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .publicProfileCompactSurface(cornerRadius: 14)
    }
}
