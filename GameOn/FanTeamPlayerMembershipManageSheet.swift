import SwiftUI

// MARK: - Overview membership manage presentation

enum FanTeamPlayerMembershipManagePresentation {
    /// Any active account seat on this Team may manage THEIR OWN managed players + Myself player flag.
    /// Team role (owner/manager/captain/member/…) does not matter.
    static func showsManageControl(hasActiveAccountMembership: Bool) -> Bool {
        hasActiveAccountMembership
    }

    /// Keep listing seats when present; also keep the card visible when the viewer
    /// has an account seat and still owns managed players to place on this Team.
    static func shouldShowOverviewSection(
        subjects: [FanTeamPlayerInfoSubject],
        hasActiveAccountMembership: Bool,
        globalManagedPlayerCount: Int
    ) -> Bool {
        if !subjects.isEmpty { return true }
        return hasActiveAccountMembership && globalManagedPlayerCount > 0
    }

    /// Overview / Manage: show when the viewer has account access and/or any account-linked players.
    static func shouldShowAccountPlayersSection(
        hasActiveAccountMembership: Bool,
        globalManagedPlayerCount: Int,
        onTeamPlayerSubjectCount: Int
    ) -> Bool {
        if onTeamPlayerSubjectCount > 0 { return true }
        if hasActiveAccountMembership { return true }
        return globalManagedPlayerCount > 0 && onTeamPlayerSubjectCount > 0
    }

    static func statusCaption(isOnTeam: Bool, languageCode: String) -> String {
        L10n.t(
            isOnTeam
                ? "team_player_membership_status_on_team"
                : "team_player_membership_status_not_on_team",
            languageCode: languageCode
        )
    }

    /// Myself stays an account identity after `is_player=false`.
    static func myselfStatusCaption(isPlayer: Bool, languageCode: String) -> String {
        L10n.t(
            isPlayer
                ? "team_player_membership_status_on_team"
                : "team_player_membership_status_not_on_team_as_player",
            languageCode: languageCode
        )
    }

    /// Same 36pt circular account avatar as managed-player rows. Never SF Symbol.
    static let myselfAvatarSize: CGFloat = 36

    static func myselfAvatarRefreshToken(
        userId: UUID?,
        thumbnailURL: String?,
        avatarURL: String?
    ) -> UUID {
        guard let userId else { return UserAvatarView.placeholderRefreshToken }
        return UserAvatarView.stableRefreshToken(
            userId: userId,
            thumbnailURL: thumbnailURL,
            avatarURL: avatarURL
        )
    }

    static func removeConfirmTitle(displayName: String, languageCode: String) -> String {
        String(
            format: L10n.t(
                "team_player_membership_remove_confirm_title_format",
                languageCode: languageCode
            ),
            locale: Locale(identifier: languageCode),
            displayName
        )
    }

    static func removeMyselfConfirmTitle(languageCode: String) -> String {
        L10n.t("team_player_membership_remove_myself_confirm_title", languageCode: languageCode)
    }
}

// MARK: - Manage sheet row model

struct FanTeamManagedPlayerMembershipRow: Identifiable, Equatable, Sendable {
    var id: UUID { managedPlayerId }
    let managedPlayerId: UUID
    let displayName: String
    let avatarURL: String?
    let avatarThumbnailURL: String?
    /// Active seat on this Team, when present.
    let membershipId: UUID?
    var isOnTeam: Bool { membershipId != nil }
}

/// Overview compact row: Myself and/or managed players with On Team / Not on Team.
struct FanTeamAccountPlayerOverviewRow: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case myself
        case managed(managedPlayerId: UUID)
    }

    let id: String
    let kind: Kind
    let displayName: String
    let identityCaptionKey: String
    let isOnTeam: Bool
    /// Player Info membership when on team as a player.
    let membershipId: UUID?
    let avatarURL: String?
    let avatarThumbnailURL: String?

    static func myself(
        displayName: String,
        isOnTeam: Bool,
        membershipId: UUID?
    ) -> FanTeamAccountPlayerOverviewRow {
        FanTeamAccountPlayerOverviewRow(
            id: "myself",
            kind: .myself,
            displayName: displayName,
            identityCaptionKey: "team_player_selector_myself",
            isOnTeam: isOnTeam,
            membershipId: membershipId,
            avatarURL: nil,
            avatarThumbnailURL: nil
        )
    }

    static func managed(
        player: FanManagedPlayer,
        membershipId: UUID?
    ) -> FanTeamAccountPlayerOverviewRow {
        FanTeamAccountPlayerOverviewRow(
            id: player.id.uuidString.lowercased(),
            kind: .managed(managedPlayerId: player.id),
            displayName: player.displayName,
            identityCaptionKey: "team_invite_managed_caption",
            isOnTeam: membershipId != nil,
            membershipId: membershipId,
            avatarURL: player.avatarURL,
            avatarThumbnailURL: player.avatarThumbnailURL
        )
    }
}

enum FanTeamAccountPlayerOverviewPresentation {
    /// Ordered Myself (optional) then managed A→Z — full account set, not only on-team.
    static func rows(
        hasAccountSeat: Bool,
        myselfDisplayName: String?,
        myselfIsPlayer: Bool,
        myselfMembershipId: UUID?,
        managedPlayers: [FanManagedPlayer],
        managedSeats: [FanTeamManagedPlayerSeat]
    ) -> [FanTeamAccountPlayerOverviewRow] {
        var out: [FanTeamAccountPlayerOverviewRow] = []
        if hasAccountSeat {
            let name = (myselfDisplayName ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(
                .myself(
                    displayName: name.isEmpty ? "Fan" : name,
                    isOnTeam: myselfIsPlayer,
                    membershipId: myselfIsPlayer ? myselfMembershipId : nil
                )
            )
        }
        let seatByManagedId = Dictionary(
            uniqueKeysWithValues: managedSeats.map { ($0.managedPlayerId, $0) }
        )
        let managedRows = managedPlayers
            .map { player in
                FanTeamAccountPlayerOverviewRow.managed(
                    player: player,
                    membershipId: seatByManagedId[player.id]?.id
                )
            }
            .sorted {
                if $0.isOnTeam != $1.isOnTeam { return $0.isOnTeam && !$1.isOnTeam }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        out.append(contentsOf: managedRows)
        return out
    }
}

// MARK: - Sheet

/// Member self-service sheet: toggle Myself player seat + add/remove managed players.
/// Removing Myself sets `is_player=false` (keeps Team access). Server remains authoritative.
struct FanTeamPlayerMembershipManageSheet: View {
    let teamId: UUID
    let teamName: String
    let languageCode: String
    let accent: Color
    /// Viewer account seat display name when `hasAccountSeat`.
    let myselfDisplayName: String?
    /// Cached account avatar (parent profile / roster). No extra fetch.
    let myselfUserId: UUID?
    let myselfAvatarURL: String?
    let myselfAvatarThumbnailURL: String?
    /// Current `is_player` for the account seat (false = access-only).
    let myselfIsPlayer: Bool
    /// `myselfIsPlayer` is set after a Myself toggle; `nil` for managed-seat add/remove.
    let onMembershipChanged: (_ myselfIsPlayer: Bool?) -> Void
    let onAddManagedPlayer: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var rows: [FanTeamManagedPlayerMembershipRow] = []
    @State private var isLoading = true
    @State private var busyManagedPlayerId: UUID?
    @State private var isBusyMyself = false
    @State private var localMyselfIsPlayer: Bool
    @State private var errorText: String?
    @State private var pendingRemove: FanTeamManagedPlayerMembershipRow?
    @State private var showRemoveConfirm = false
    @State private var showRemoveMyselfConfirm = false

    private let managedService = FanManagedPlayerService()
    private let teamsService = FanTeamsService()

    init(
        teamId: UUID,
        teamName: String,
        languageCode: String,
        accent: Color,
        myselfDisplayName: String?,
        myselfUserId: UUID?,
        myselfAvatarURL: String?,
        myselfAvatarThumbnailURL: String?,
        myselfIsPlayer: Bool,
        onMembershipChanged: @escaping (_ myselfIsPlayer: Bool?) -> Void,
        onAddManagedPlayer: @escaping () -> Void
    ) {
        self.teamId = teamId
        self.teamName = teamName
        self.languageCode = languageCode
        self.accent = accent
        self.myselfDisplayName = myselfDisplayName
        self.myselfUserId = myselfUserId
        self.myselfAvatarURL = myselfAvatarURL
        self.myselfAvatarThumbnailURL = myselfAvatarThumbnailURL
        self.myselfIsPlayer = myselfIsPlayer
        self.onMembershipChanged = onMembershipChanged
        self.onAddManagedPlayer = onAddManagedPlayer
        _localMyselfIsPlayer = State(initialValue: myselfIsPlayer)
    }

    private var sortedRows: [FanTeamManagedPlayerMembershipRow] {
        rows.sorted {
            if $0.isOnTeam != $1.isOnTeam { return $0.isOnTeam && !$1.isOnTeam }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private var showsMyselfRow: Bool {
        myselfDisplayName != nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && rows.isEmpty && !showsMyselfRow {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if rows.isEmpty && !showsMyselfRow {
                    emptyManagedPlayersState
                } else {
                    List {
                        Section {
                            if showsMyselfRow {
                                myselfToggleRow
                            }
                            ForEach(sortedRows) { row in
                                membershipRow(row)
                            }
                        } header: {
                            Text(L10n.t("team_player_membership_manage_section_header", languageCode: languageCode))
                        } footer: {
                            Text(
                                L10n.t(
                                    "team_player_membership_manage_helper",
                                    languageCode: languageCode
                                )
                            )
                        }

                        if let errorText {
                            Section {
                                Text(errorText)
                                    .font(.footnote)
                                    .foregroundStyle(FGColor.dangerRed)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(L10n.t("team_player_membership_manage_title", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Done", languageCode: languageCode)) { dismiss() }
                        .disabled(busyManagedPlayerId != nil || isBusyMyself)
                }
            }
            .confirmationDialog(
                pendingRemove.map {
                    FanTeamPlayerMembershipManagePresentation.removeConfirmTitle(
                        displayName: $0.displayName,
                        languageCode: languageCode
                    )
                } ?? "",
                isPresented: $showRemoveConfirm,
                titleVisibility: .visible
            ) {
                Button(
                    L10n.t("team_player_membership_remove_action", languageCode: languageCode),
                    role: .destructive
                ) {
                    guard let pendingRemove else { return }
                    Task { await removeFromTeam(pendingRemove) }
                }
                Button(L10n.t("Cancel", languageCode: languageCode), role: .cancel) {
                    pendingRemove = nil
                }
            } message: {
                Text(L10n.t("team_player_membership_remove_confirm_message", languageCode: languageCode))
            }
            .confirmationDialog(
                FanTeamPlayerMembershipManagePresentation.removeMyselfConfirmTitle(
                    languageCode: languageCode
                ),
                isPresented: $showRemoveMyselfConfirm,
                titleVisibility: .visible
            ) {
                Button(
                    L10n.t("team_player_membership_remove_myself_action", languageCode: languageCode),
                    role: .destructive
                ) {
                    Task { await setMyselfIsPlayer(false) }
                }
                Button(L10n.t("Cancel", languageCode: languageCode), role: .cancel) {}
            } message: {
                Text(L10n.t("team_player_membership_remove_myself_confirm_message", languageCode: languageCode))
            }
            .task { await reload() }
            .onChange(of: myselfIsPlayer) { _, newValue in
                guard !isBusyMyself else { return }
                localMyselfIsPlayer = newValue
            }
        }
    }

    private var emptyManagedPlayersState: some View {
        VStack(spacing: FGSpacing.lg) {
            ContentUnavailableView(
                L10n.t("team_player_membership_empty_title", languageCode: languageCode),
                systemImage: "figure.and.child.holdinghands",
                description: Text(
                    L10n.t("team_player_membership_empty_body", languageCode: languageCode)
                )
            )

            Button {
                onAddManagedPlayer()
            } label: {
                Text(L10n.t("team_player_membership_add_managed_player", languageCode: languageCode))
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .padding(.horizontal, 24)

            if let errorText {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(FGColor.dangerRed)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var myselfToggleRow: some View {
        let name = (myselfDisplayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: localMyselfIsPlayer ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(
                        localMyselfIsPlayer ? FGColor.accentGreen : FGColor.mutedText(colorScheme)
                    )
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)

                UserAvatarView(
                    avatarThumbnailURL: myselfAvatarThumbnailURL,
                    avatarURL: myselfAvatarURL ?? "",
                    avatarDisplayRefreshToken: FanTeamPlayerMembershipManagePresentation.myselfAvatarRefreshToken(
                        userId: myselfUserId,
                        thumbnailURL: myselfAvatarThumbnailURL,
                        avatarURL: myselfAvatarURL
                    ),
                    displayName: name.isEmpty ? "Fan" : name,
                    email: "",
                    size: FanTeamPlayerMembershipManagePresentation.myselfAvatarSize,
                    fallbackStyle: colorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome
                )
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name.isEmpty ? "Fan" : name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text(L10n.t("team_player_selector_myself", languageCode: languageCode))
                        .font(.footnote)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                    Text(
                        FanTeamPlayerMembershipManagePresentation.myselfStatusCaption(
                            isPlayer: localMyselfIsPlayer,
                            languageCode: languageCode
                        )
                    )
                    .font(.footnote)
                    .foregroundStyle(
                        localMyselfIsPlayer
                            ? FGColor.accentGreen
                            : FGColor.secondaryText(colorScheme)
                    )
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isBusyMyself else { return }
                if localMyselfIsPlayer {
                    showRemoveMyselfConfirm = true
                } else {
                    Task { await setMyselfIsPlayer(true) }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(name.isEmpty ? "Fan" : name), \(L10n.t("team_player_selector_myself", languageCode: languageCode)), \(FanTeamPlayerMembershipManagePresentation.myselfStatusCaption(isPlayer: localMyselfIsPlayer, languageCode: languageCode))"
            )
            .accessibilityAddTraits(.isButton)

            if isBusyMyself {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func membershipRow(_ row: FanTeamManagedPlayerMembershipRow) -> some View {
        let isBusy = busyManagedPlayerId == row.managedPlayerId
        return HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: row.isOnTeam ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(
                        row.isOnTeam ? FGColor.accentGreen : FGColor.mutedText(colorScheme)
                    )
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)

                ManagedPlayerAvatarView(
                    managedPlayerId: row.managedPlayerId,
                    avatarURL: row.avatarURL,
                    avatarThumbnailURL: row.avatarThumbnailURL,
                    displayName: row.displayName,
                    size: 36
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.displayName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text(L10n.t("team_invite_managed_caption", languageCode: languageCode))
                        .font(.footnote)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                    Text(
                        FanTeamPlayerMembershipManagePresentation.statusCaption(
                            isOnTeam: row.isOnTeam,
                            languageCode: languageCode
                        )
                    )
                    .font(.footnote)
                    .foregroundStyle(
                        row.isOnTeam
                            ? FGColor.accentGreen
                            : FGColor.secondaryText(colorScheme)
                    )
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isBusy, !row.isOnTeam else { return }
                Task { await addToTeam(row) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(row.displayName), \(FanTeamPlayerMembershipManagePresentation.statusCaption(isOnTeam: row.isOnTeam, languageCode: languageCode))"
            )
            .accessibilityHint(
                row.isOnTeam
                    ? ""
                    : L10n.t("team_player_membership_add_a11y_hint", languageCode: languageCode)
            )
            .accessibilityAddTraits(row.isOnTeam ? [] : .isButton)

            if row.isOnTeam {
                Button(role: .destructive) {
                    pendingRemove = row
                    showRemoveConfirm = true
                } label: {
                    Text(L10n.t("team_player_membership_remove_action", languageCode: languageCode))
                        .font(.subheadline.weight(.semibold))
                }
                .disabled(isBusy)
                .accessibilityHint(
                    L10n.t("team_player_membership_remove_a11y_hint", languageCode: languageCode)
                )
            }

            if isBusy {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    @MainActor
    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let allPlayers = managedService.listMyManagedPlayers()
            async let seats = managedService.listMyManagedPlayersOnTeam(teamId: teamId)
            let players = try await allPlayers
            let onTeam = try await seats
            let seatByManagedId = Dictionary(
                uniqueKeysWithValues: onTeam.map { ($0.managedPlayerId, $0) }
            )
            rows = players.map { player in
                let seat = seatByManagedId[player.id]
                return FanTeamManagedPlayerMembershipRow(
                    managedPlayerId: player.id,
                    displayName: player.displayName,
                    avatarURL: player.avatarURL,
                    avatarThumbnailURL: player.avatarThumbnailURL,
                    membershipId: seat?.id
                )
            }
            errorText = nil
        } catch {
            if FanTeamsLoadErrorPresentation.isCancellation(error) { return }
            errorText = FanTeamsLoadErrorPresentation.userFacingMessage(
                for: error,
                languageCode: languageCode
            ) ?? error.localizedDescription
        }
    }

    @MainActor
    private func setMyselfIsPlayer(_ isPlayer: Bool) async {
        guard !isBusyMyself else { return }
        let previous = localMyselfIsPlayer
        isBusyMyself = true
        localMyselfIsPlayer = isPlayer
        defer { isBusyMyself = false }
        do {
            let applied = try await teamsService.setMyPlayerParticipation(teamId: teamId, isPlayer: isPlayer)
            localMyselfIsPlayer = applied
            errorText = nil
#if DEBUG
            await teamsService.traceAccountSeatAfterMyselfToggle(
                teamId: teamId,
                expectedIsPlayer: applied
            )
#endif
            onMembershipChanged(applied)
        } catch {
            localMyselfIsPlayer = previous
            if FanTeamsLoadErrorPresentation.isCancellation(error) { return }
            FanTeamRPCTrace.log(
                step: "A.sheet.catch",
                rpc: "set_my_fan_team_is_player",
                error: error,
                extra: "requestedIsPlayer=\(isPlayer) mutationCommitted=NO phase=duringMutation"
            )
            errorText = FanTeamsLoadErrorPresentation.userFacingMessage(
                for: error,
                layer: .membershipUpdate,
                languageCode: languageCode
            ) ?? error.localizedDescription
        }
    }

    @MainActor
    private func addToTeam(_ row: FanTeamManagedPlayerMembershipRow) async {
        guard !row.isOnTeam, busyManagedPlayerId == nil else { return }
        if rows.contains(where: { $0.managedPlayerId == row.managedPlayerId && $0.isOnTeam }) {
            return
        }
        busyManagedPlayerId = row.managedPlayerId
        defer { busyManagedPlayerId = nil }
        do {
            let membershipId = try await managedService.addManagedPlayerToTeam(
                teamId: teamId,
                managedPlayerId: row.managedPlayerId
            )
            FanManagedPlayerChangeCenter.postTeamMembershipChange(
                FanManagedPlayerTeamMembershipChange(
                    managedPlayerId: row.managedPlayerId,
                    teamId: teamId,
                    membershipId: membershipId,
                    added: true
                )
            )
            if let idx = rows.firstIndex(where: { $0.managedPlayerId == row.managedPlayerId }) {
                rows[idx] = FanTeamManagedPlayerMembershipRow(
                    managedPlayerId: row.managedPlayerId,
                    displayName: row.displayName,
                    avatarURL: row.avatarURL,
                    avatarThumbnailURL: row.avatarThumbnailURL,
                    membershipId: membershipId
                )
            }
            errorText = nil
            onMembershipChanged(nil)
            await reload()
        } catch {
            if FanTeamsLoadErrorPresentation.isCancellation(error) { return }
            let combined = String(describing: error).lowercased()
            if combined.contains("already") || combined.contains("duplicate") {
                onMembershipChanged(nil)
                await reload()
                return
            }
            errorText = FanTeamsLoadErrorPresentation.userFacingMessage(
                for: error,
                languageCode: languageCode
            ) ?? error.localizedDescription
        }
    }

    @MainActor
    private func removeFromTeam(_ row: FanTeamManagedPlayerMembershipRow) async {
        guard let membershipId = row.membershipId, busyManagedPlayerId == nil else { return }
        busyManagedPlayerId = row.managedPlayerId
        defer {
            busyManagedPlayerId = nil
            pendingRemove = nil
        }
        do {
            try await teamsService.removeMembership(membershipId: membershipId)
            FanManagedPlayerChangeCenter.postTeamMembershipChange(
                FanManagedPlayerTeamMembershipChange(
                    managedPlayerId: row.managedPlayerId,
                    teamId: teamId,
                    membershipId: membershipId,
                    added: false
                )
            )
            if let idx = rows.firstIndex(where: { $0.managedPlayerId == row.managedPlayerId }) {
                rows[idx] = FanTeamManagedPlayerMembershipRow(
                    managedPlayerId: row.managedPlayerId,
                    displayName: row.displayName,
                    avatarURL: row.avatarURL,
                    avatarThumbnailURL: row.avatarThumbnailURL,
                    membershipId: nil
                )
            }
            errorText = nil
            onMembershipChanged(nil)
            await reload()
        } catch {
            if FanTeamsLoadErrorPresentation.isCancellation(error) { return }
            errorText = FanTeamsLoadErrorPresentation.userFacingMessage(
                for: error,
                languageCode: languageCode
            ) ?? L10n.t("fan_teams_remove_member_failed", languageCode: languageCode)
        }
    }
}
