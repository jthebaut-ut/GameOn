import SwiftUI

/// Who a Team action applies to: the signed-in adult, or one of their managed players.
enum TeamPlayerChoice: Identifiable, Equatable, Hashable, Sendable {
    case myself
    case managedPlayer(FanManagedPlayer)

    var id: String {
        switch self {
        case .myself: return "self"
        case let .managedPlayer(player): return player.id.uuidString
        }
    }

    var managedPlayerId: UUID? {
        if case let .managedPlayer(player) = self { return player.id }
        return nil
    }

    func title(languageCode: String) -> String {
        switch self {
        case .myself:
            return L10n.t("team_player_selector_myself", languageCode: languageCode)
        case let .managedPlayer(player):
            return player.displayName
        }
    }
}

/// Stable multi-select seat identity for invitation join (account self XOR managed player).
enum TeamInviteSeatSelection: Hashable, Sendable {
    case myself
    case managedPlayer(UUID)

    var managedPlayerId: UUID? {
        if case let .managedPlayer(id) = self { return id }
        return nil
    }

    var includesSelf: Bool {
        if case .myself = self { return true }
        return false
    }
}

/// Decides whether a "who is joining?" step is worth showing at all.
///
/// This is the single place that keeps the feature zero-friction: a user with no
/// managed players has exactly one choice, so the selector is skipped entirely
/// and the caller runs the unchanged self path.
enum TeamPlayerSelection {
    static func choices(managedPlayers: [FanManagedPlayer]) -> [TeamPlayerChoice] {
        [.myself] + managedPlayers.map { TeamPlayerChoice.managedPlayer($0) }
    }

    static func requiresSelection(managedPlayers: [FanManagedPlayer]) -> Bool {
        !managedPlayers.isEmpty
    }

    /// Returns the only possible choice when no prompt is warranted.
    static func autoResolvedChoice(managedPlayers: [FanManagedPlayer]) -> TeamPlayerChoice? {
        requiresSelection(managedPlayers: managedPlayers) ? nil : .myself
    }

    /// Invitation Accept always opens the multi-select sheet so guardians can
    /// attach Myself, children, or both — and create another player mid-flow.
    static func shouldPresentInvitationJoinSheet(managedPlayers _: [FanManagedPlayer]) -> Bool {
        true
    }
}

/// Reusable single-select "Who is joining?" / "Switch Player" sheet.
struct TeamPlayerSelectorView: View {
    let titleKey: String
    let managedPlayers: [FanManagedPlayer]
    let languageCode: String
    var allowsAddPlayer: Bool = true
    let onSelect: (TeamPlayerChoice) -> Void
    var onAddPlayer: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(TeamPlayerSelection.choices(managedPlayers: managedPlayers)) { choice in
                    Button {
                        onSelect(choice)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            avatar(for: choice)
                            Text(choice.title(languageCode: languageCode))
                                .font(.body)
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                            Spacer(minLength: 0)
                        }
                    }
                }
            } footer: {
                Text(L10n.t("team_player_selector_footer", languageCode: languageCode))
            }

            if allowsAddPlayer, let onAddPlayer {
                Section {
                    Button {
                        onAddPlayer()
                        dismiss()
                    } label: {
                        Label(
                            L10n.t("managed_players_add", languageCode: languageCode),
                            systemImage: "plus.circle"
                        )
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t(titleKey, languageCode: languageCode))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.t("Cancel", languageCode: languageCode)) { dismiss() }
            }
        }
    }

    @ViewBuilder
    private func avatar(for choice: TeamPlayerChoice) -> some View {
        switch choice {
        case .myself:
            Image(systemName: "person.crop.circle")
                .font(.system(size: 30))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .frame(width: 36, height: 36)
        case let .managedPlayer(player):
            ManagedPlayerAvatarView(
                managedPlayerId: player.id,
                avatarURL: player.avatarURL,
                avatarThumbnailURL: player.avatarThumbnailURL,
                displayName: player.displayName,
                size: 36
            )
        }
    }
}

/// Multi-select invitation join: Myself and/or one-or-more managed players.
struct TeamInvitationJoinSheet: View {
    let teamName: String
    let selfDisplayName: String
    let selfAvatarURL: String?
    let selfAvatarThumbnailURL: String?
    let managedPlayers: [FanManagedPlayer]
    let languageCode: String
    var initiallySelectedManagedPlayerId: UUID? = nil
    let onJoin: (_ includeSelf: Bool, _ managedPlayerIds: [UUID]) -> Void
    let onAddPlayer: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var selection: Set<TeamInviteSeatSelection> = []
    @State private var isJoining = false
    @State private var didApplyInitialSelection = false

    private var canJoin: Bool {
        !isJoining && !selection.isEmpty
    }

    var body: some View {
        List {
            Section {
                selfRow
                ForEach(managedPlayers) { player in
                    managedRow(player)
                }
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        String(
                            format: L10n.t("team_invite_who_joining_format", languageCode: languageCode),
                            locale: Locale(identifier: languageCode),
                            teamName
                        )
                    )
                    .font(.headline)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .textCase(nil)

                    Text(L10n.t("team_invite_who_joining_subtitle", languageCode: languageCode))
                        .font(.footnote)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .textCase(nil)
                }
                .padding(.bottom, 4)
            }

            Section {
                Button {
                    onAddPlayer()
                } label: {
                    Label(
                        L10n.t("team_invite_add_another", languageCode: languageCode),
                        systemImage: "plus.circle"
                    )
                }
                .accessibilityHint(L10n.t("managed_players_add", languageCode: languageCode))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("team_player_selector_join_title", languageCode: languageCode))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.t("Cancel", languageCode: languageCode)) { dismiss() }
                    .disabled(isJoining)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.t("team_invite_join_team", languageCode: languageCode)) {
                    join()
                }
                .disabled(!canJoin)
                .fontWeight(.semibold)
            }
        }
        .onAppear {
            applyDefaultSelectionIfNeeded()
        }
        .onChange(of: managedPlayers.map(\.id)) { _, ids in
            selection = selection.filter { seat in
                switch seat {
                case .myself: return true
                case let .managedPlayer(id): return ids.contains(id)
                }
            }
            if let preselect = initiallySelectedManagedPlayerId,
               ids.contains(preselect) {
                selection.insert(.managedPlayer(preselect))
            }
        }
    }

    private func applyDefaultSelectionIfNeeded() {
        guard !didApplyInitialSelection else { return }
        didApplyInitialSelection = true
        if let preselect = initiallySelectedManagedPlayerId,
           managedPlayers.contains(where: { $0.id == preselect }) {
            selection = [.managedPlayer(preselect)]
        } else if selection.isEmpty {
            selection = [.myself]
        }
    }

    private var selfRow: some View {
        Button {
            toggle(.myself)
        } label: {
            HStack(spacing: 12) {
                selectionMark(selected: selection.contains(.myself))
                UserAvatarView(
                    avatarThumbnailURL: selfAvatarThumbnailURL,
                    avatarURL: selfAvatarURL ?? "",
                    avatarDisplayRefreshToken: UUID(),
                    displayName: selfDisplayName,
                    email: "",
                    size: 40
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(selfDisplayName.isEmpty
                       ? L10n.t("team_player_selector_myself", languageCode: languageCode)
                       : selfDisplayName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text(L10n.t("team_invite_myself_caption", languageCode: languageCode))
                        .font(.footnote)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection.contains(.myself) ? [.isSelected] : [])
    }

    private func managedRow(_ player: FanManagedPlayer) -> some View {
        let seat = TeamInviteSeatSelection.managedPlayer(player.id)
        return Button {
            toggle(seat)
        } label: {
            HStack(spacing: 12) {
                selectionMark(selected: selection.contains(seat))
                ManagedPlayerAvatarView(
                    managedPlayerId: player.id,
                    avatarURL: player.avatarURL,
                    avatarThumbnailURL: player.avatarThumbnailURL,
                    displayName: player.displayName,
                    size: 40
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.displayName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text(L10n.t("team_invite_managed_caption", languageCode: languageCode))
                        .font(.footnote)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection.contains(seat) ? [.isSelected] : [])
    }

    private func selectionMark(selected: Bool) -> some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 22))
            .foregroundStyle(selected ? Color.accentColor : FGColor.secondaryText(colorScheme))
            .accessibilityHidden(true)
    }

    private func toggle(_ seat: TeamInviteSeatSelection) {
        if selection.contains(seat) {
            selection.remove(seat)
        } else {
            selection.insert(seat)
        }
    }

    private func join() {
        guard canJoin else { return }
        isJoining = true
        let includeSelf = selection.contains(.myself)
        let managedIds = selection.compactMap(\.managedPlayerId)
        onJoin(includeSelf, managedIds)
        dismiss()
    }
}
