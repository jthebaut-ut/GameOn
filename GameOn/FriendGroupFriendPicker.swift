import SwiftUI

// MARK: - Multi-select friend picker (reusable)

struct FriendGroupFriendPicker: View {
    let title: String
    let candidates: [FriendGroupSelectableFriend]
    @ObservedObject var selection: FriendGroupSelectionStore
    let languageCode: String
    let confirmTitleFormatKey: String
    let isSubmitting: Bool
    let errorText: String?
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var searchText = ""

    private var filtered: [FriendGroupSelectableFriend] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return candidates }
        return candidates.filter {
            $0.displayName.localizedCaseInsensitiveContains(q)
                || ($0.username?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private var confirmTitle: String {
        String(
            format: L10n.t(confirmTitleFormatKey, languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            Int64(selection.selectedCount)
        )
    }

    var body: some View {
        NavigationStack {
            List {
                if !candidates.isEmpty {
                    Section {
                        Button {
                            selection.selectAll(from: filtered)
                        } label: {
                            Label(
                                L10n.t("friend_groups_select_all", languageCode: languageCode),
                                systemImage: "checkmark.circle"
                            )
                        }
                        .disabled(filtered.isEmpty || isSubmitting)
                    }
                }

                Section {
                    if filtered.isEmpty {
                        Text(L10n.t("friend_groups_no_friends_match", languageCode: languageCode))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    } else {
                        ForEach(filtered) { friend in
                            Button {
                                selection.toggle(friend.id)
                            } label: {
                                HStack(spacing: 12) {
                                    ProfileAvatarView(preview: friend.preview, size: 40)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(friend.displayName)
                                            .foregroundStyle(FGColor.primaryText(colorScheme))
                                        if let username = friend.username?
                                            .trimmingCharacters(in: .whitespacesAndNewlines),
                                           !username.isEmpty {
                                            Text(FanGeoHandleRules.displayHandle(stored: username))
                                                .font(.caption)
                                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                        }
                                    }
                                    Spacer()
                                    Image(
                                        systemName: selection.isSelected(friend.id)
                                            ? "checkmark.circle.fill"
                                            : "circle"
                                    )
                                    .foregroundStyle(
                                        selection.isSelected(friend.id)
                                            ? FGColor.accentGreen
                                            : FGColor.mutedText(colorScheme)
                                    )
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                String(
                                    format: L10n.t(
                                        selection.isSelected(friend.id)
                                            ? "friend_groups_a11y_friend_selected"
                                            : "friend_groups_a11y_friend_unselected",
                                        languageCode: languageCode
                                    ),
                                    locale: Locale(identifier: languageCode),
                                    friend.displayName
                                )
                            )
                            .disabled(isSubmitting)
                        }
                    }
                }
            }
            .searchable(
                text: $searchText,
                prompt: L10n.t("friend_groups_search_friends", languageCode: languageCode)
            )
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel", languageCode: languageCode)) { onCancel() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle) { onConfirm() }
                        .disabled(isSubmitting)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let errorText, !errorText.isEmpty {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.ultraThinMaterial)
                }
            }
            .overlay {
                if isSubmitting {
                    ProgressView()
                }
            }
        }
    }
}

// MARK: - Assign one friend to multiple groups (••• menu)

struct FriendAddToGroupsSheet: View {
    let friend: FriendGroupSelectableFriend
    let groups: [FriendGroup]
    let initiallySelectedGroupIds: Set<UUID>
    let languageCode: String
    let onSave: (_ selectedGroupIds: Set<UUID>) async throws -> Void
    let onCreateGroup: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedIds: Set<UUID>
    @State private var isSubmitting = false
    @State private var errorText: String?

    init(
        friend: FriendGroupSelectableFriend,
        groups: [FriendGroup],
        initiallySelectedGroupIds: Set<UUID>,
        languageCode: String,
        onSave: @escaping (_ selectedGroupIds: Set<UUID>) async throws -> Void,
        onCreateGroup: @escaping () -> Void
    ) {
        self.friend = friend
        self.groups = groups
        self.initiallySelectedGroupIds = initiallySelectedGroupIds
        self.languageCode = languageCode
        self.onSave = onSave
        self.onCreateGroup = onCreateGroup
        _selectedIds = State(initialValue: initiallySelectedGroupIds)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onCreateGroup()
                    } label: {
                        Label(
                            L10n.t("friend_groups_new_group", languageCode: languageCode),
                            systemImage: "plus.circle.fill"
                        )
                    }
                }

                Section {
                    if groups.isEmpty {
                        Text(L10n.t("friend_groups_empty_title", languageCode: languageCode))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    } else {
                        ForEach(groups) { group in
                            Button {
                                if selectedIds.contains(group.id) {
                                    selectedIds.remove(group.id)
                                } else {
                                    selectedIds.insert(group.id)
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(group.name)
                                            .foregroundStyle(FGColor.primaryText(colorScheme))
                                        Text(
                                            FriendGroupPresentation.memberCountLabel(
                                                count: group.memberCount,
                                                languageCode: languageCode
                                            )
                                        )
                                        .font(.caption)
                                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                                    }
                                    Spacer()
                                    Image(
                                        systemName: selectedIds.contains(group.id)
                                            ? "checkmark.circle.fill"
                                            : "circle"
                                    )
                                    .foregroundStyle(
                                        selectedIds.contains(group.id)
                                            ? FGColor.accentGreen
                                            : FGColor.mutedText(colorScheme)
                                    )
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(isSubmitting)
                        }
                    }
                } header: {
                    Text(L10n.t("friend_groups_add_to_group_title", languageCode: languageCode))
                }
            }
            .navigationTitle(L10n.t("friend_groups_add_to_group_title", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel", languageCode: languageCode)) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Save", languageCode: languageCode)) {
                        Task { await save() }
                    }
                    .disabled(isSubmitting)
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
    private func save() async {
        isSubmitting = true
        errorText = nil
        do {
            try await onSave(selectedIds)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
        isSubmitting = false
    }
}

// MARK: - Browse groups → expand members → multi-select (future Team/Event/Chat hook)

/// Reusable Groups browser for invite flows. Returns selected friend user IDs.
struct FriendGroupsBrowseAndSelectView: View {
    let groups: [FriendGroup]
    let acceptedFriends: [FriendGroupSelectableFriend]
    let languageCode: String
    let loadMemberIds: (UUID) async throws -> [UUID]
    let onConfirm: (Set<UUID>) -> Void
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var selection = FriendGroupSelectionStore()
    @State private var expandedGroupId: UUID?
    @State private var expandedMembers: [FriendGroupSelectableFriend] = []
    @State private var isLoadingMembers = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                if let expandedGroupId,
                   let group = groups.first(where: { $0.id == expandedGroupId }) {
                    Section {
                        Button {
                            selection.selectAll(from: expandedMembers)
                        } label: {
                            Label(
                                L10n.t("friend_groups_select_all", languageCode: languageCode),
                                systemImage: "checkmark.circle"
                            )
                        }
                        .disabled(expandedMembers.isEmpty)

                        ForEach(expandedMembers) { friend in
                            Button {
                                selection.toggle(friend.id)
                            } label: {
                                HStack(spacing: 12) {
                                    ProfileAvatarView(preview: friend.preview, size: 36)
                                    Text(friend.displayName)
                                        .foregroundStyle(FGColor.primaryText(colorScheme))
                                    Spacer()
                                    Image(
                                        systemName: selection.isSelected(friend.id)
                                            ? "checkmark.circle.fill"
                                            : "circle"
                                    )
                                    .foregroundStyle(
                                        selection.isSelected(friend.id)
                                            ? FGColor.accentGreen
                                            : FGColor.mutedText(colorScheme)
                                    )
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text(group.name)
                    } footer: {
                        Button(L10n.t("friend_groups_back_to_groups", languageCode: languageCode)) {
                            self.expandedGroupId = nil
                            expandedMembers = []
                        }
                    }
                } else {
                    Section {
                        if groups.isEmpty {
                            Text(L10n.t("friend_groups_empty_title", languageCode: languageCode))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                        } else {
                            ForEach(groups) { group in
                                Button {
                                    Task { await openGroup(group) }
                                } label: {
                                    HStack {
                                        Text(group.name)
                                            .foregroundStyle(FGColor.primaryText(colorScheme))
                                        Spacer()
                                        Text("\(group.memberCount)")
                                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(FGColor.mutedText(colorScheme))
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(
                                    FriendGroupPresentation.accessibilityGroupLabel(
                                        name: group.name,
                                        memberCount: group.memberCount,
                                        languageCode: languageCode
                                    )
                                )
                            }
                        }
                    } header: {
                        Text(L10n.t("friend_groups_groups", languageCode: languageCode))
                    }
                }
            }
            .navigationTitle(L10n.t("friend_groups_title", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel", languageCode: languageCode)) { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        String(
                            format: L10n.t("friend_groups_invite_count_format", languageCode: languageCode),
                            locale: Locale(identifier: languageCode),
                            Int64(selection.selectedCount)
                        )
                    ) {
                        onConfirm(selection.selectedIds)
                    }
                    .disabled(selection.selectedCount == 0)
                }
            }
            .overlay {
                if isLoadingMembers {
                    ProgressView()
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
    private func openGroup(_ group: FriendGroup) async {
        isLoadingMembers = true
        errorText = nil
        do {
            let ids = try await loadMemberIds(group.id)
            let idSet = Set(ids)
            expandedMembers = acceptedFriends.filter { idSet.contains($0.id) }
            expandedGroupId = group.id
        } catch {
            errorText = error.localizedDescription
        }
        isLoadingMembers = false
    }
}
