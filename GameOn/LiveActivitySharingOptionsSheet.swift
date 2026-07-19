import SwiftUI

struct LiveActivitySharingOptionsSheet: View {
    let isEnabled: Bool
    let mode: LiveVisibilityMode
    let friends: [ChatViewModel.FriendDisplay]
    let selectedFriendIDs: Set<UUID>
    let isSaving: Bool
    let onChooseOff: () -> Void
    let onChooseAllFriends: () -> Void
    let onChooseSelectedFriends: () -> Void
    let onLoadFriends: () -> Void
    let onToggleFriend: (UUID) -> Void
    let onClose: () -> Void
    var embedsInNavigationStack = true
    var showsCloseButton = true

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @State private var isSelectedFriendsExpanded = false

    @ViewBuilder
    var body: some View {
        if embedsInNavigationStack {
            NavigationStack {
                content
            }
        } else {
            content
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FGSpacing.md) {
                Text(L10n.t("live_sharing_choose_who_can_see", languageCode: appLanguageRaw))
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                    .padding(.horizontal, FGSpacing.xs)

                VStack(alignment: .leading, spacing: 0) {
                    optionRow(
                        title: L10n.t("live_sharing_off", languageCode: appLanguageRaw),
                        subtitle: L10n.t("live_sharing_off_subtitle", languageCode: appLanguageRaw),
                        systemImage: "eye.slash.fill",
                        isSelected: !isEnabled,
                        action: onChooseOff
                    )

                    optionDivider()

                    optionRow(
                        title: L10n.t("live_sharing_all_friends", languageCode: appLanguageRaw),
                        subtitle: L10n.t("live_sharing_all_friends_subtitle", languageCode: appLanguageRaw),
                        systemImage: "person.2.fill",
                        isSelected: isEnabled && mode == .allFriends,
                        action: onChooseAllFriends
                    )

                    optionDivider()

                    selectedFriendsSection()
                }
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                            .fill(.ultraThinMaterial)
                        RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                            .fill(SettingsPremiumChrome.cardFill(colorScheme))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                        .strokeBorder(SettingsPremiumChrome.cardStroke(colorScheme), lineWidth: 0.75)
                }
            }
            .padding(FGSpacing.lg)
        }
        .background(FGColor.screenGradient(colorScheme).ignoresSafeArea())
        .navigationTitle(L10n.t("share_my_fan_activity_title", languageCode: appLanguageRaw))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Close", languageCode: appLanguageRaw), action: onClose)
                }
            }
        }
        .tint(FGColor.accentGreen)
        .onAppear {
            isSelectedFriendsExpanded = isEnabled && mode == .selectedFriends
            if isSelectedFriendsExpanded {
                onLoadFriends()
            }
        }
        .onChange(of: mode) { _, newMode in
            guard newMode != .selectedFriends else { return }
            withAnimation(.snappy(duration: 0.22)) {
                isSelectedFriendsExpanded = false
            }
        }
    }

    private func optionDivider() -> some View {
        Divider()
            .overlay(SettingsPremiumChrome.divider(colorScheme))
            .opacity(0.42)
            .padding(.leading, 58)
            .padding(.trailing, FGSpacing.md)
    }

    private func optionRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: FGSpacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(SettingsPremiumChrome.iconSurface(colorScheme))
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(FGColor.accentBlue)
                }
                .frame(width: SettingsPremiumChrome.rowIconSize, height: SettingsPremiumChrome.rowIconSize)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(FGColor.accentGreen)
                }
            }
            .padding(.horizontal, FGSpacing.md)
            .padding(.vertical, 12)
            .frame(minHeight: SettingsPremiumChrome.rowMinHeight, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
    }

    private func selectedFriendsSection() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.24)) {
                    isSelectedFriendsExpanded.toggle()
                }
                if isSelectedFriendsExpanded {
                    onLoadFriends()
                    onChooseSelectedFriends()
                }
            } label: {
                HStack(alignment: .center, spacing: FGSpacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(SettingsPremiumChrome.iconSurface(colorScheme))
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(FGColor.accentBlue)
                    }
                    .frame(width: SettingsPremiumChrome.rowIconSize, height: SettingsPremiumChrome.rowIconSize)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.t("Selected Friends", languageCode: appLanguageRaw))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                        Text(selectedFriendsSubtitle)
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else if isEnabled && mode == .selectedFriends {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(FGColor.accentGreen)
                    }

                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
                        .rotationEffect(.degrees(isSelectedFriendsExpanded ? 0 : -90))
                        .frame(width: 16, height: 16)
                        .animation(.snappy(duration: 0.22), value: isSelectedFriendsExpanded)
                }
                .padding(.horizontal, FGSpacing.md)
                .padding(.vertical, 12)
                .frame(minHeight: SettingsPremiumChrome.rowMinHeight, alignment: .center)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSaving && !(isEnabled && mode == .selectedFriends))

            if isSelectedFriendsExpanded {
                optionDivider()
                selectedFriendsList()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.snappy(duration: 0.24), value: isSelectedFriendsExpanded)
    }

    private var selectedFriendsSubtitle: String {
        guard isEnabled && mode == .selectedFriends else {
            return L10n.t("live_sharing_pick_specific_friends", languageCode: appLanguageRaw)
        }
        switch selectedFriendIDs.count {
        case 0:
            return L10n.t("live_sharing_no_friends_selected", languageCode: appLanguageRaw)
        case 1:
            return L10n.t("live_sharing_one_friend_can_see", languageCode: appLanguageRaw)
        default:
            return String(
                format: L10n.t("live_sharing_friends_can_see_format", languageCode: appLanguageRaw),
                locale: Locale(identifier: appLanguageRaw),
                selectedFriendIDs.count
            )
        }
    }

    @ViewBuilder
    private func selectedFriendsList() -> some View {
        if friends.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "person.2.slash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
                    .frame(width: 32, height: 32)
                Text(L10n.t("live_sharing_accepted_friends_appear_here", languageCode: appLanguageRaw))
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, FGSpacing.md)
            .padding(.vertical, 10)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(friends) { friend in
                    selectedFriendRow(friend)
                    if friend.id != friends.last?.id {
                        optionDivider()
                    }
                }
            }
        }
    }

    private func selectedFriendRow(_ friend: ChatViewModel.FriendDisplay) -> some View {
        Button {
            guard !isSaving else { return }
            onToggleFriend(friend.id)
        } label: {
            HStack(spacing: 10) {
                SocialAvatarRenderer.socialAvatarView(for: friend.preview, size: 34)
                    .frame(width: 34, height: 34)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(friend.preview.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? L10n.t("Friend", languageCode: appLanguageRaw)
                         : friend.preview.displayName)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                        .lineLimit(1)
                    Text(friend.preview.publicHandleLine)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: selectedFriendIDs.contains(friend.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19, weight: selectedFriendIDs.contains(friend.id) ? .semibold : .regular))
                    .foregroundStyle(selectedFriendIDs.contains(friend.id) ? FGColor.accentGreen : SettingsPremiumChrome.mutedText(colorScheme))
            }
            .padding(.leading, FGSpacing.md)
            .padding(.trailing, FGSpacing.md)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
    }
}
