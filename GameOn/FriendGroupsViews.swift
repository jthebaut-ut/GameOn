import Combine
import SwiftUI

// MARK: - Friends · All / Groups switcher content

enum FriendDirectoryMode: String, CaseIterable, Identifiable {
    case allFriends
    case groups

    var id: String { rawValue }

    func title(languageCode: String) -> String {
        switch self {
        case .allFriends:
            return L10n.t("friend_groups_all_friends", languageCode: languageCode)
        case .groups:
            return L10n.t("friend_groups_groups", languageCode: languageCode)
        }
    }
}

struct FriendDirectoryModePicker: View {
    @Binding var mode: FriendDirectoryMode
    let languageCode: String
    let colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: 8) {
            ForEach(FriendDirectoryMode.allCases) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        mode = item
                    }
                } label: {
                    Text(item.title(languageCode: languageCode))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(
                            mode == item
                                ? FGColor.primaryText(colorScheme)
                                : FGColor.secondaryText(colorScheme)
                        )
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule(style: .continuous)
                                .fill(
                                    mode == item
                                        ? FGAdaptiveSurface.cardElevated(colorScheme)
                                        : Color.clear
                                )
                        )
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    FGColor.divider(colorScheme).opacity(mode == item ? 0.55 : 0.28),
                                    lineWidth: 1
                                )
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == item ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("friend_groups_title", languageCode: languageCode))
    }
}

// MARK: - Groups list

struct FriendGroupsListView: View {
    let groups: [FriendGroup]
    let languageCode: String
    let isLoading: Bool
    /// Optional already-resolved member faces keyed by group id (no network).
    var memberPreviewsByGroupId: [UUID: [UserPreview]] = [:]
    let onRefresh: () async -> Void
    let onSelect: (FriendGroup) -> Void
    let onCreate: () -> Void
    var onRename: ((FriendGroup) -> Void)? = nil
    var onDelete: ((FriendGroup) -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if isLoading && groups.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.isEmpty {
                FriendGroupsEmptyStateView(languageCode: languageCode, onCreate: onCreate)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        FriendGroupCreateHeroCard(
                            languageCode: languageCode,
                            action: onCreate
                        )

                        Text(L10n.t("friend_groups_groups", languageCode: languageCode))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .textCase(.uppercase)
                            .padding(.top, 6)
                            .accessibilityAddTraits(.isHeader)

                        ForEach(groups) { group in
                            FriendGroupPremiumCard(
                                group: group,
                                languageCode: languageCode,
                                memberPreviews: memberPreviewsByGroupId[group.id] ?? [],
                                onSelect: { onSelect(group) },
                                onRename: { onRename?(group) },
                                onDelete: { onDelete?(group) }
                            )
                        }

                        FriendGroupPrivacyCard(languageCode: languageCode)
                            .padding(.top, 4)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 110)
                }
                .refreshable { await onRefresh() }
            }
        }
    }
}

// MARK: - Create / Rename sheets

struct FriendGroupNameEditorSheet: View {
    enum Mode {
        case create
        case rename(FriendGroup)

        var navigationTitleKey: String {
            switch self {
            case .create: return "friend_groups_create_title"
            case .rename: return "friend_groups_rename_title"
            }
        }

        var confirmKey: String {
            switch self {
            case .create: return "friend_groups_create_action"
            case .rename: return "Save"
            }
        }
    }

    let mode: Mode
    let languageCode: String
    let onSubmit: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var isSubmitting = false
    @State private var errorText: String?

    init(mode: Mode, languageCode: String, onSubmit: @escaping (String) async throws -> Void) {
        self.mode = mode
        self.languageCode = languageCode
        self.onSubmit = onSubmit
        switch mode {
        case .create:
            _name = State(initialValue: "")
        case .rename(let group):
            _name = State(initialValue: group.name)
        }
    }

    private var canSubmit: Bool {
        FriendGroupNameValidation.isValid(name) && !isSubmitting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        L10n.t("friend_groups_name_placeholder", languageCode: languageCode),
                        text: $name
                    )
                    .textInputAutocapitalization(.words)
                    .disabled(isSubmitting)
                } header: {
                    Text(L10n.t("friend_groups_name_label", languageCode: languageCode))
                } footer: {
                    Text(
                        String(
                            format: L10n.t("friend_groups_name_footer", languageCode: languageCode),
                            locale: Locale(identifier: languageCode),
                            Int64(FriendGroupNameValidation.maxLength)
                        )
                    )
                }
            }
            .navigationTitle(L10n.t(mode.navigationTitleKey, languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel", languageCode: languageCode)) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t(mode.confirmKey, languageCode: languageCode)) {
                        Task { await submit() }
                    }
                    .disabled(!canSubmit)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let errorText, !errorText.isEmpty {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding()
                }
            }
        }
    }

    @MainActor
    private func submit() async {
        guard canSubmit else { return }
        isSubmitting = true
        errorText = nil
        do {
            try await onSubmit(name)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
        isSubmitting = false
    }
}

// MARK: - Group detail

struct FriendGroupDetailView: View {
    let group: FriendGroup
    let members: [FriendGroupSelectableFriend]
    let languageCode: String
    let isBusy: Bool
    let onRefresh: () async -> Void
    let onAddFriends: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onRemoveMember: (FriendGroupSelectableFriend) -> Void
    let onOpenProfile: (FriendGroupSelectableFriend) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var searchText = ""

    private var artwork: FriendGroupArtwork {
        FriendGroupArtworkResolver.resolve(groupName: group.name)
    }

    private var filtered: [FriendGroupSelectableFriend] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return members }
        return members.filter {
            $0.displayName.localizedCaseInsensitiveContains(q)
                || ($0.username?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heroHeader

                actionRow

                searchField

                membersSection

                FriendGroupPrivacyCard(languageCode: languageCode)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(FGColor.screenGradient(colorScheme).ignoresSafeArea())
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await onRefresh() }
        .overlay {
            if isBusy {
                ProgressView()
                    .padding(18)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                FriendGroupArtworkBadge(artwork: artwork, size: 56, cornerStyle: .roundedSquare)

                VStack(alignment: .leading, spacing: 6) {
                    Text(group.name)
                        .font(FGTypography.screenTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)

                    Text(
                        FriendGroupPresentation.memberCountLabel(
                            count: members.count,
                            languageCode: languageCode
                        )
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                }

                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                FriendGroupPresentation.accessibilityGroupLabel(
                    name: group.name,
                    memberCount: members.count,
                    languageCode: languageCode
                )
            )

            FriendGroupAvatarStack(
                previews: members.map(\.preview),
                totalCount: members.count,
                maxVisible: 5,
                diameter: 32
            )
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            FriendGroupDetailActionChip(
                title: L10n.t("friend_groups_add_friends", languageCode: languageCode),
                systemImage: "person.badge.plus",
                action: onAddFriends
            )
            FriendGroupDetailActionChip(
                title: L10n.t("friend_groups_rename", languageCode: languageCode),
                systemImage: "pencil",
                action: onRename
            )
            FriendGroupDetailActionChip(
                title: L10n.t("friend_groups_delete", languageCode: languageCode),
                systemImage: "trash",
                isDestructive: true,
                action: onDelete
            )
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(FGColor.mutedText(colorScheme))
            TextField(
                L10n.t("friend_groups_search_in_group", languageCode: languageCode),
                text: $searchText
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("Cancel", languageCode: languageCode))
            }
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.72 : 0.92))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.45), lineWidth: 1)
        }
        .softCardShadow()
        .accessibilityLabel(L10n.t("friend_groups_search_in_group", languageCode: languageCode))
    }

    @ViewBuilder
    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("friend_groups_members_section", languageCode: languageCode))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)

            if members.isEmpty {
                Text(L10n.t("friend_groups_no_members", languageCode: languageCode))
                    .font(.subheadline)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
                    .padding(.horizontal, 14)
                    .background(
                        RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                            .fill(FGAdaptiveSurface.cardElevated(colorScheme).opacity(0.85))
                    )
            } else if filtered.isEmpty {
                Text(L10n.t("friend_groups_no_friends_match", languageCode: languageCode))
                    .font(.subheadline)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 22)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(filtered) { friend in
                        FriendGroupMemberCard(
                            friend: friend,
                            languageCode: languageCode,
                            onOpen: { onOpenProfile(friend) },
                            onRemove: { onRemoveMember(friend) }
                        )
                        .accessibilityHint(
                            String(
                                format: L10n.t(
                                    "friend_groups_a11y_remove_member",
                                    languageCode: languageCode
                                ),
                                locale: Locale(identifier: languageCode),
                                friend.displayName,
                                group.name
                            )
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Host container used by Friends tab

@MainActor
final class FriendGroupsStore: ObservableObject {
    @Published private(set) var groups: [FriendGroup] = []
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    private let service: FriendGroupService
    private var refreshGeneration = 0

    /// Default service is constructed in the MainActor init body (not as a default-argument
    /// expression). `FriendGroupService.init(client:)` reads the MainActor `supabase` global;
    /// evaluating that default argument from a synchronous nonisolated context warns.
    init(service: FriendGroupService? = nil) {
        self.service = service ?? FriendGroupService()
    }

    func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isLoading = true
        lastError = nil
        do {
            let next = try await service.listMyFriendGroups()
            guard generation == refreshGeneration else { return }
            groups = next
        } catch {
            guard generation == refreshGeneration else { return }
            lastError = error.localizedDescription
        }
        if generation == refreshGeneration {
            isLoading = false
        }
    }

    @discardableResult
    func create(name: String) async throws -> FriendGroup {
        let group = try await service.createFriendGroup(name: name)
        await refresh()
        return group
    }

    @discardableResult
    func rename(groupId: UUID, name: String) async throws -> FriendGroup {
        let group = try await service.renameFriendGroup(groupId: groupId, name: name)
        await refresh()
        return group
    }

    func delete(groupId: UUID) async throws {
        try await service.deleteFriendGroup(groupId: groupId)
        await refresh()
    }

    func memberIds(groupId: UUID) async throws -> [UUID] {
        try await service.listFriendGroupMemberIds(groupId: groupId)
    }

    func setMembers(groupId: UUID, friendUserIds: [UUID]) async throws {
        try await service.setFriendGroupMembers(groupId: groupId, friendUserIds: friendUserIds)
        await refresh()
    }

    func setMembership(friendUserId: UUID, groupIds: [UUID]) async throws {
        try await service.setFriendMembershipInGroups(friendUserId: friendUserId, groupIds: groupIds)
        await refresh()
    }

    func groupsContaining(friendUserId: UUID) async throws -> [FriendGroup] {
        try await service.listMyFriendGroupsContainingFriend(friendUserId: friendUserId)
    }
}
