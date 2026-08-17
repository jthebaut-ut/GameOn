import SwiftUI

// MARK: - Nested editor destination (owned by Player Information)

/// Single presentation owner for editors opened from Player Information.
/// Prevents parent-level sheets from queuing behind an already-presented modal.
enum FanTeamPlayerInfoEditorDestination: String, Identifiable, Hashable, Sendable {
    case jerseyNumber
    case position
    case teamRole

    var id: String { rawValue }
}

/// Compact Team-specific player metadata leaf (jersey + preferred position + status).
/// Does not edit profile identity. Edit affordances are permission-gated independently.
/// Bound to the selected ``FanTeamMember`` identity (not `auth.uid`) for future managed-player compatibility.
///
/// Child editors (jersey / position / role) are presented **from this sheet** so they open
/// immediately while Player Information remains visible.
///
/// `member` is a **Binding** so role/jersey/position mutations that update the parent’s
/// canonical roster (and this binding) refresh immediately without dismissing the sheet.
struct FanTeamPlayerInformationSheet: View {
    @Binding var member: FanTeamMember
    let team: FanTeamSummary
    let teamAccent: Color
    let languageCode: String
    var currentUserId: UUID? = nil
    var isSavingPlayerNumber: Bool = false
    var isSavingPreferredPosition: Bool = false
    var isSavingTeamRole: Bool = false
    var isSavingPermissions: Bool = false
    /// Existing Team persistence paths — no duplicate save logic.
    var onSavePlayerNumber: (Int?) async -> Void
    var onClearPlayerNumber: () async -> Void
    var onSavePreferredPosition: (String?) async -> Void
    var onSaveTeamRole: ((FanTeamMemberRole) async throws -> Void)? = nil
    /// Owner-only: persist custom permission set for this account seat.
    var onSavePermissions: ((FanTeamPermissionSet) async throws -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var editorDestination: FanTeamPlayerInfoEditorDestination?
    @State private var roleSaveError: String?
    @State private var permissionsSaveError: String?
    @State private var isSavingAdministrator = false

    private var canEditNumber: Bool { team.canManageRoster }

    private var canEditPosition: Bool {
        team.canManageLineup && FanTeamSportPositions.supportsPositions(forSportToken: team.sport)
    }

    /// Role assignment is Owner-only; Owner target is never assignable here.
    private var canEditTeamRole: Bool {
        guard team.canAssignRoles else { return false }
        guard member.role != .owner else { return false }
        if let currentUserId, member.userId == currentUserId { return false }
        return onSaveTeamRole != nil
    }

    private var canEditPermissions: Bool {
        FanTeamPermissions.canEditPermissions(
            viewerRole: team.myRole,
            targetRole: member.role,
            targetIsManagedPlayer: member.isManagedPlayer,
            viewerUserId: currentUserId,
            targetUserId: member.userId
        ) && onSavePermissions != nil
    }

    private var showsPositionRow: Bool {
        canEditPosition
            || FanTeamSportPositions.supportsPositions(forSportToken: team.sport)
            || member.preferredPositionCode != nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    headerRow
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                Section {
                    jerseyNumberRow
                    if showsPositionRow {
                        preferredPositionRow
                    }
                } header: {
                    Text(L10n.t("fan_teams_player_details", languageCode: languageCode))
                }

                Section {
                    teamRoleRow
                    if canEditPermissions {
                        teamAdministratorToggleRow
                    }
                    memberSinceRow
                } header: {
                    Text(L10n.t("fan_teams_team_status", languageCode: languageCode))
                } footer: {
                    if canEditPermissions {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.t("fan_team_administrator_footer", languageCode: languageCode))
                                .font(.footnote)
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                            if let permissionsSaveError, !permissionsSaveError.isEmpty {
                                Text(permissionsSaveError)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(FGColor.accentYellow)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .fanGeoScreenBackground()
            .navigationTitle(L10n.t("fan_teams_player_information", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("Done", languageCode: languageCode)) {
                        logPresentation("playerInfoDismissed", detail: "reason=done")
                        editorDestination = nil
                        dismiss()
                    }
                }
            }
        }
        .sheet(item: $editorDestination, onDismiss: {
            logPresentation("childEditorDismissed", detail: "member=\(member.membershipId.uuidString.lowercased())")
        }) { destination in
            childEditor(for: destination)
        }
        .onAppear {
            logPresentation(
                "playerInfoPresented",
                detail: "membership=\(member.membershipId.uuidString.lowercased())"
            )
        }
        .onDisappear {
            // Cancel any nested destination so nothing can present after this sheet is gone.
            if editorDestination != nil {
                logPresentation("destinationClearedOnDisappear", detail: "hadPending=true")
            }
            editorDestination = nil
            logPresentation("playerInfoDismissed", detail: "reason=disappear")
        }
        .onChange(of: editorDestination) { _, newValue in
            logPresentation(
                "destinationChanged",
                detail: newValue.map { "destination=\($0.rawValue)" } ?? "destination=nil"
            )
            if newValue != nil {
                logPresentation("childEditorPresented", detail: "destination=\(newValue!.rawValue)")
            }
        }
    }

    @ViewBuilder
    private var teamAdministratorToggleRow: some View {
        let enabled = FanTeamPermissions.isTeamAdministrator(
            role: member.role,
            effective: member.effectivePermissions
        )
        let busy = isSavingPermissions || isSavingAdministrator
        Toggle(isOn: Binding(
            get: { enabled },
            set: { newValue in
                guard canEditPermissions, !busy else { return }
                guard newValue != enabled else { return }
                let next = FanTeamPermissions.grantedSet(isTeamAdministrator: newValue)
                isSavingAdministrator = true
                permissionsSaveError = nil
                Task { @MainActor in
                    defer { isSavingAdministrator = false }
                    do {
                        try await onSavePermissions?(next)
                    } catch {
                        permissionsSaveError = error.localizedDescription
                    }
                }
            }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("fan_team_administrator_title", languageCode: languageCode))
                    .font(.body)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text(L10n.t("fan_team_administrator_help", languageCode: languageCode))
                    .font(.footnote)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(busy)
        .tint(teamAccent)
        .accessibilityLabel(L10n.t("fan_team_administrator_title", languageCode: languageCode))
        .accessibilityHint(L10n.t("fan_team_administrator_help", languageCode: languageCode))
    }

    @ViewBuilder
    private func childEditor(for destination: FanTeamPlayerInfoEditorDestination) -> some View {
        switch destination {
        case .jerseyNumber:
            FanTeamPlayerNumberEditorSheet(
                memberName: member.displayName,
                initialNumber: member.playerNumber,
                teamAccent: teamAccent,
                languageCode: languageCode,
                isSaving: isSavingPlayerNumber,
                onSave: { number in
                    Task { @MainActor in
                        await onSavePlayerNumber(number)
                        editorDestination = nil
                    }
                },
                onClear: {
                    Task { @MainActor in
                        await onClearPlayerNumber()
                        editorDestination = nil
                    }
                },
                onCancel: {
                    editorDestination = nil
                }
            )
        case .position:
            FanTeamSportPositionPickerSheet(
                sportToken: team.sport,
                selectedCode: member.preferredPositionCode,
                onSelect: { code in
                    Task { @MainActor in
                        await onSavePreferredPosition(code)
                        editorDestination = nil
                    }
                },
                navigationTitleKey: "fan_teams_position",
                clearTitleKey: "fan_team_lineup_no_position"
            )
        case .teamRole:
            FanTeamMemberRolePickerSheet(
                member: member,
                languageCode: languageCode,
                isSaving: isSavingTeamRole,
                errorText: roleSaveError,
                onSelect: { role in
                    roleSaveError = nil
                    do {
                        try await onSaveTeamRole?(role)
                        editorDestination = nil
                    } catch {
                        roleSaveError = error.localizedDescription
                    }
                }
            )
        }
    }

    private var headerRow: some View {
        HStack(spacing: 14) {
            Group {
                if let preview = member.preview {
                    ProfileAvatarView(preview: preview, size: 56)
                } else {
                    // Managed player: avatar comes from the roster row, not a profile.
                    ManagedPlayerAvatarView(
                        managedPlayerId: member.managedPlayerId,
                        avatarURL: member.avatarURL,
                        avatarThumbnailURL: member.avatarThumbnailURL,
                        displayName: member.displayName,
                        size: 56
                    )
                }
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let handle = FanTeamRosterRowPresentation.parentheticalHandle(
                    username: member.username
                ) {
                    Text(handle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            FanTeamRosterRowPresentation.identityLine(
                displayName: member.displayName,
                username: member.username
            )
        )
    }

    @ViewBuilder
    private var jerseyNumberRow: some View {
        let value = FanTeamMyPlayerInfoPresentation.jerseyDisplayValue(
            playerNumber: member.playerNumber,
            languageCode: languageCode
        )
        let title = L10n.t("fan_teams_jersey_number", languageCode: languageCode)
        if canEditNumber {
            Button {
                logPresentation("jerseyTapped")
                editorDestination = .jerseyNumber
            } label: {
                metaRow(title: title, value: value, showsChevron: true)
            }
            .disabled(isSavingPlayerNumber || editorDestination != nil)
            .accessibilityLabel("\(title), \(value)")
            .accessibilityHint(
                L10n.t("fan_teams_player_info_change_number_a11y", languageCode: languageCode)
            )
        } else {
            metaRow(title: title, value: value, showsChevron: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(title), \(value)")
        }
    }

    @ViewBuilder
    private var preferredPositionRow: some View {
        let value = FanTeamMyPlayerInfoPresentation.positionDisplayValue(
            preferredPositionCode: member.preferredPositionCode,
            sportToken: team.sport,
            languageCode: languageCode
        )
        let title = L10n.t("fan_teams_position", languageCode: languageCode)
        if canEditPosition {
            Button {
                logPresentation("positionTapped")
                editorDestination = .position
            } label: {
                metaRow(title: title, value: value, showsChevron: true)
            }
            .disabled(isSavingPreferredPosition || editorDestination != nil)
            .accessibilityLabel("\(title), \(value)")
            .accessibilityHint(
                L10n.t("fan_teams_player_info_change_position_a11y", languageCode: languageCode)
            )
        } else {
            metaRow(title: title, value: value, showsChevron: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(title), \(value)")
        }
    }

    @ViewBuilder
    private var teamRoleRow: some View {
        let title = L10n.t("fan_teams_team_role", languageCode: languageCode)
        let value = L10n.t(member.role.localizedKey, languageCode: languageCode)
        if canEditTeamRole, onSaveTeamRole != nil {
            Button {
                logPresentation("roleTapped")
                editorDestination = .teamRole
            } label: {
                metaRow(title: title, value: value, showsChevron: true)
            }
            .disabled(editorDestination != nil || isSavingTeamRole)
            .accessibilityLabel("\(title), \(value)")
            .accessibilityHint(
                L10n.t("fan_teams_choose_role_help", languageCode: languageCode)
            )
        } else {
            metaRow(title: title, value: value, showsChevron: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(title), \(value)")
        }
    }

    private var memberSinceRow: some View {
        let title = L10n.t("fan_teams_member_since", languageCode: languageCode)
        let value = FanTeamMyPlayerInfoPresentation.memberSinceDisplayValue(
            joinedAt: member.joinedAt,
            languageCode: languageCode
        )
        return metaRow(title: title, value: value, showsChevron: false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(value)")
    }

    private func metaRow(title: String, value: String, showsChevron: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.body)
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(value)
                .font(.body)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

#if DEBUG
    private func logPresentation(_ event: String, detail: String = "") {
        let suffix = detail.isEmpty ? "" : " \(detail)"
        print("[PlayerInfoPresentation] \(event)\(suffix)")
    }
#else
    private func logPresentation(_ event: String, detail: String = "") {}
#endif
}

/// Apple-style Team Role selection leaf. Uses existing assignable roles only (not Owner).
struct FanTeamMemberRolePickerSheet: View {
    let member: FanTeamMember
    let languageCode: String
    var isSaving: Bool = false
    var errorText: String? = nil
    var onSelect: (FanTeamMemberRole) async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var pendingRole: FanTeamMemberRole?

    private var isBusy: Bool { isSaving || pendingRole != nil }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(FanTeamMemberRole.assignableViaRolePicker, id: \.self) { role in
                        Button {
                            guard member.role != role else {
                                dismiss()
                                return
                            }
                            guard !isBusy else { return }
                            pendingRole = role
                            Task { @MainActor in
                                await onSelect(role)
                                pendingRole = nil
                            }
                        } label: {
                            HStack {
                                Text(L10n.t(role.localizedKey, languageCode: languageCode))
                                    .foregroundStyle(FGColor.primaryText(colorScheme))
                                Spacer()
                                if pendingRole == role, isBusy {
                                    ProgressView()
                                        .controlSize(.small)
                                } else if member.role == role {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(FGColor.accentGreen)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .disabled(isBusy)
                        .accessibilityLabel(L10n.t(role.localizedKey, languageCode: languageCode))
                        .accessibilityAddTraits(member.role == role ? [.isSelected] : [])
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.t("fan_teams_choose_role_help", languageCode: languageCode))
                            .font(.footnote)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                        if let errorText, !errorText.isEmpty {
                            Text(errorText)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(FGColor.accentYellow)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .fanGeoScreenBackground()
            .navigationTitle(L10n.t("fan_teams_team_role", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel", languageCode: languageCode)) { dismiss() }
                        .disabled(isBusy)
                }
            }
            .interactiveDismissDisabled(isBusy)
        }
    }
}
