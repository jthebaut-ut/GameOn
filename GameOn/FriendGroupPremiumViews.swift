import SwiftUI

// MARK: - Motion

struct FriendGroupCardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.96 : 1)
            .animation(.easeInOut(duration: 0.16), value: configuration.isPressed)
    }
}

// MARK: - Avatar stack

struct FriendGroupAvatarStack: View {
    let previews: [UserPreview]
    var totalCount: Int
    var maxVisible: Int = 3
    var diameter: CGFloat = 28

    @Environment(\.colorScheme) private var colorScheme

    private var visible: [UserPreview] {
        Array(previews.prefix(maxVisible))
    }

    private var overflow: Int {
        max(totalCount - visible.count, 0)
    }

    var body: some View {
        if totalCount <= 0 {
            EmptyView()
        } else {
            HStack(spacing: -diameter * 0.34) {
                if visible.isEmpty {
                    ForEach(0..<min(totalCount, maxVisible), id: \.self) { _ in
                        placeholderAvatar
                    }
                } else {
                    ForEach(visible, id: \.id) { preview in
                        ProfileAvatarView(preview: preview, size: diameter)
                            .overlay(
                                Circle()
                                    .strokeBorder(
                                        colorScheme == .dark
                                            ? Color.black.opacity(0.35)
                                            : Color.white,
                                        lineWidth: 1.5
                                    )
                            )
                    }
                }

                if overflow > 0 {
                    Text("+\(overflow)")
                        .font(.system(size: max(10, diameter * 0.34), weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .frame(width: diameter, height: diameter)
                        .background(
                            Circle().fill(FGAdaptiveSurface.cardElevated(colorScheme))
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    colorScheme == .dark
                                        ? Color.white.opacity(0.18)
                                        : Color.white,
                                    lineWidth: 1.5
                                )
                        )
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(totalCount)"))
        }
    }

    private var placeholderAvatar: some View {
        Circle()
            .fill(FGColor.cardBackground(colorScheme))
            .frame(width: diameter, height: diameter)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: diameter * 0.38, weight: .semibold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            }
            .overlay(
                Circle()
                    .strokeBorder(FGColor.divider(colorScheme).opacity(0.55), lineWidth: 1)
            )
    }
}

// MARK: - Hero create card

struct FriendGroupCreateHeroCard: View {
    let languageCode: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    FGColor.gradientStart.opacity(colorScheme == .dark ? 0.55 : 0.95),
                                    FGColor.gradientMiddle.opacity(colorScheme == .dark ? 0.75 : 0.90),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 46, height: 46)
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t("friend_groups_create_new_group", languageCode: languageCode))
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.t("friend_groups_create_hero_body", languageCode: languageCode))
                        .font(.subheadline)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background {
                RoundedRectangle(cornerRadius: FGRadius.card, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: colorScheme == .dark
                                ? [
                                    Color(red: 0.14, green: 0.20, blue: 0.30).opacity(0.92),
                                    Color(red: 0.10, green: 0.14, blue: 0.22).opacity(0.88),
                                ]
                                : [
                                    Color.white.opacity(0.96),
                                    Color(red: 0.93, green: 0.96, blue: 1.0).opacity(0.96),
                                ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: FGRadius.card, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                FGColor.gradientMiddle.opacity(colorScheme == .dark ? 0.45 : 0.35),
                                FGColor.accentGreen.opacity(colorScheme == .dark ? 0.28 : 0.22),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .softCardShadow()
        }
        .buttonStyle(FriendGroupCardPressStyle())
        .accessibilityLabel(L10n.t("friend_groups_create_new_group", languageCode: languageCode))
        .accessibilityHint(L10n.t("friend_groups_create_hero_body", languageCode: languageCode))
    }
}

// MARK: - Group list card

struct FriendGroupPremiumCard: View {
    let group: FriendGroup
    let languageCode: String
    let memberPreviews: [UserPreview]
    let onSelect: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var artwork: FriendGroupArtwork {
        FriendGroupArtworkResolver.resolve(groupName: group.name)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onSelect) {
                HStack(alignment: .center, spacing: 12) {
                    FriendGroupArtworkBadge(artwork: artwork, size: 52, cornerStyle: .circle)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.name)
                            .font(FGTypography.cardTitle)
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(
                            FriendGroupPresentation.memberCountLabel(
                                count: group.memberCount,
                                languageCode: languageCode
                            )
                        )
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))

                        FriendGroupAvatarStack(
                            previews: memberPreviews,
                            totalCount: group.memberCount,
                            maxVisible: 3,
                            diameter: 28
                        )
                        .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(FriendGroupCardPressStyle())

            Menu {
                Button(action: onRename) {
                    Label(
                        L10n.t("friend_groups_rename", languageCode: languageCode),
                        systemImage: "pencil"
                    )
                }
                Button(role: .destructive, action: onDelete) {
                    Label(
                        L10n.t("friend_groups_delete", languageCode: languageCode),
                        systemImage: "trash"
                    )
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }

            Button(action: onSelect) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .frame(minWidth: 28, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: FGRadius.card, style: .continuous)
                .fill(FGAdaptiveSurface.cardElevated(colorScheme).opacity(colorScheme == .dark ? 0.92 : 0.98))
        }
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.card, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.45), lineWidth: 1)
        }
        .softCardShadow()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            FriendGroupPresentation.accessibilityGroupLabel(
                name: group.name,
                memberCount: group.memberCount,
                languageCode: languageCode
            )
        )
    }
}

// MARK: - Empty state

struct FriendGroupsEmptyStateView: View {
    let languageCode: String
    let onCreate: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 24)

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                FGColor.gradientStart.opacity(colorScheme == .dark ? 0.35 : 0.85),
                                FGColor.gradientMiddle.opacity(colorScheme == .dark ? 0.45 : 0.70),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 118, height: 118)
                Image(systemName: "person.3.sequence.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolRenderingMode(.hierarchical)
            }
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(L10n.t("friend_groups_empty_title", languageCode: languageCode))
                    .font(FGTypography.sectionTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.center)
                Text(L10n.t("friend_groups_empty_body", languageCode: languageCode))
                    .font(.subheadline)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
            }

            Button(action: onCreate) {
                Label(
                    L10n.t("friend_groups_create_new_group", languageCode: languageCode),
                    systemImage: "plus"
                )
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .background(FGColor.brandGradient, in: Capsule(style: .continuous))
            }
            .buttonStyle(FriendGroupCardPressStyle())

            FriendGroupPrivacyCard(languageCode: languageCode)
                .padding(.horizontal, 8)
                .padding(.top, 8)

            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }
}

// MARK: - Privacy card

struct FriendGroupPrivacyCard: View {
    let languageCode: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(FGColor.accentGreen)
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.22 : 0.16))
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("friend_groups_privacy_title", languageCode: languageCode))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.t("friend_groups_privacy_body", languageCode: languageCode))
                    .font(.footnote)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.14 : 0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                .strokeBorder(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.28 : 0.22), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Detail action chip

struct FriendGroupDetailActionChip: View {
    let title: String
    let systemImage: String
    var isDestructive: Bool = false
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isDestructive ? FGColor.dangerRed : FGColor.primaryText(colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                        .fill(FGAdaptiveSurface.controlFill(colorScheme))
                )
        }
        .buttonStyle(FriendGroupCardPressStyle())
        .accessibilityLabel(title)
    }
}

// MARK: - Detail member card

struct FriendGroupMemberCard: View {
    let friend: FriendGroupSelectableFriend
    let languageCode: String
    let onOpen: () -> Void
    let onRemove: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    ProfileAvatarView(preview: friend.preview, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(friend.displayName)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(1)
                        if let username = friend.username?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                           !username.isEmpty {
                            Text(FanGeoHandleRules.displayHandle(stored: username))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button(action: onOpen) {
                    Label(
                        L10n.t("View Profile", languageCode: languageCode),
                        systemImage: "person.crop.circle"
                    )
                }
                Button(role: .destructive, action: onRemove) {
                    Label(
                        L10n.t("friend_groups_remove_from_group", languageCode: languageCode),
                        systemImage: "person.badge.minus"
                    )
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                .fill(FGAdaptiveSurface.cardElevated(colorScheme).opacity(colorScheme == .dark ? 0.9 : 0.98))
        }
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.4), lineWidth: 1)
        }
        .contextMenu {
            Button(role: .destructive, action: onRemove) {
                Label(
                    L10n.t("friend_groups_remove_from_group", languageCode: languageCode),
                    systemImage: "person.badge.minus"
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(friend.displayName)
    }
}
