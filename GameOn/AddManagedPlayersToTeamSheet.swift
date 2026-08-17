import SwiftUI

/// Owner/Manager + guardian path: place My Players onto the open Team.
///
/// Calls `add_managed_player_to_fan_team` (requires `managed_player_team_seats`).
/// Does not invite friend accounts — use ``AddFanTeamMembersSheet`` for that.
struct AddManagedPlayersToTeamSheet: View {
    let teamId: UUID
    let teamName: String
    let languageCode: String
    /// Active managed seats already on this Team (skip in the chooser).
    let alreadyOnTeamManagedPlayerIds: Set<UUID>
    let onAdded: (_ addedManagedPlayerIds: [UUID]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var players: [FanManagedPlayer] = []
    @State private var selectedIds: Set<UUID> = []
    @State private var isLoading = true
    @State private var isSubmitting = false
    @State private var errorText: String?

    private let service = FanManagedPlayerService()

    private var candidates: [FanManagedPlayer] {
        players.filter { !alreadyOnTeamManagedPlayerIds.contains($0.id) }
    }

    var body: some View {
        Group {
            if isLoading && players.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if candidates.isEmpty {
                ContentUnavailableView(
                    L10n.t("managed_players_add_to_team_empty_title", languageCode: languageCode),
                    systemImage: "figure.and.child.holdinghands",
                    description: Text(
                        L10n.t("managed_players_add_to_team_empty_body", languageCode: languageCode)
                    )
                )
            } else {
                List {
                    Section {
                        ForEach(candidates) { player in
                            Button {
                                toggle(player.id)
                            } label: {
                                HStack(spacing: 12) {
                                    ManagedPlayerAvatarView(
                                        managedPlayerId: player.id,
                                        avatarURL: player.avatarURL,
                                        avatarThumbnailURL: player.avatarThumbnailURL,
                                        displayName: player.displayName,
                                        size: 36
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
                                    Image(
                                        systemName: selectedIds.contains(player.id)
                                            ? "checkmark.circle.fill"
                                            : "circle"
                                    )
                                    .foregroundStyle(
                                        selectedIds.contains(player.id)
                                            ? FGColor.accentGreen
                                            : FGColor.mutedText(colorScheme)
                                    )
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text(
                            String(
                                format: L10n.t(
                                    "managed_players_add_to_team_header_format",
                                    languageCode: languageCode
                                ),
                                locale: Locale(identifier: languageCode),
                                teamName
                            )
                        )
                        .textCase(nil)
                    } footer: {
                        Text(L10n.t("managed_players_add_to_team_footer", languageCode: languageCode))
                    }

                    if let errorText {
                        Section {
                            Text(errorText)
                                .foregroundStyle(FGColor.dangerRed)
                                .font(.footnote)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(L10n.t("managed_players_add_to_team", languageCode: languageCode))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.t("Cancel", languageCode: languageCode)) { dismiss() }
                    .disabled(isSubmitting)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.t("managed_players_add_to_team_confirm", languageCode: languageCode)) {
                    Task { await submit() }
                }
                .disabled(selectedIds.isEmpty || isSubmitting || candidates.isEmpty)
                .fontWeight(.semibold)
            }
        }
        .task { await reload() }
    }

    private func toggle(_ id: UUID) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            players = try await service.listMyManagedPlayers()
#if DEBUG
            print(
                "[ManagedPlayerTeamDebug] add_sheet_candidates " +
                "team_id=\(teamId.uuidString.lowercased()) " +
                "managed_players_count=\(players.count) " +
                "already_on_team_count=\(alreadyOnTeamManagedPlayerIds.count) " +
                "chooser_count=\(candidates.count)"
            )
#endif
        } catch {
            errorText = FanTeamsLoadErrorPresentation.userFacingMessage(
                for: error,
                languageCode: languageCode
            ) ?? error.localizedDescription
        }
    }

    private func submit() async {
        guard !selectedIds.isEmpty else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        var added: [UUID] = []
        do {
            for playerId in selectedIds {
                let membershipId = try await service.addManagedPlayerToTeam(
                    teamId: teamId,
                    managedPlayerId: playerId
                )
                added.append(playerId)
                FanManagedPlayerChangeCenter.postTeamMembershipChange(
                    FanManagedPlayerTeamMembershipChange(
                        managedPlayerId: playerId,
                        teamId: teamId,
                        membershipId: membershipId,
                        added: true
                    )
                )
#if DEBUG
                print(
                    "[ManagedPlayerTeamDebug] owner_direct_add " +
                    "managed_player_id=\(playerId.uuidString.lowercased()) " +
                    "team_id=\(teamId.uuidString.lowercased()) " +
                    "seat_created=true " +
                    "membership_id=\(membershipId.uuidString.lowercased()) " +
                    "left_at=nil"
                )
#endif
            }
            onAdded(added)
            dismiss()
        } catch {
#if DEBUG
            let combined = String(describing: error)
            print(
                "[ManagedPlayerTeamDebug] owner_direct_add_failed " +
                "team_id=\(teamId.uuidString.lowercased()) " +
                "added_before_fail=\(added.count) " +
                "error=\(error.localizedDescription)"
            )
            print("[ManagedPlayerTeamDebug] owner_direct_add_failed_detail=\(combined)")
            if combined.lowercased().contains("managed_player_team_seats_disabled")
                || combined.lowercased().contains("managed_player_seats_disabled") {
                print(
                    "[ManagedPlayerTeamDebug] managed_player_team_seats_enabled=false " +
                    "action=apply_20260969_0001_enable_managed_player_team_seats.sql"
                )
            }
#endif
            if !added.isEmpty {
                onAdded(added)
            }
            errorText = FanTeamsLoadErrorPresentation.userFacingMessage(
                for: error,
                languageCode: languageCode
            ) ?? error.localizedDescription
        }
    }
}
