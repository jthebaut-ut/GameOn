import PhotosUI
import SwiftUI
import UIKit

// MARK: - My Players (guardian home)

/// Guardian-facing list of managed players.
///
/// Entirely opt-in: a user with no managed players sees the empty state and can
/// leave without ever touching Teams. Nothing here creates a social identity.
struct MyPlayersView: View {
    let languageCode: String
    @ObservedObject var mapViewModel: MapViewModel
    @ObservedObject var chatViewModel: ChatViewModel
    var knownTeams: [FanTeamSummary] = []
    var currentTeamId: UUID? = nil
    var onOpenTeamChat: (FanTeamChatContext) -> Void
    var onTeamsChanged: () -> Void = {}
    var onRevealCurrentTeam: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var players: [FanManagedPlayer] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showingEditor = false
    @State private var editingPlayer: FanManagedPlayer?
    @State private var openedTeam: FanTeamSummary?

    private let service = FanManagedPlayerService()

    var body: some View {
        Group {
            if isLoading && players.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if players.isEmpty {
                MyPlayersEmptyStateView(
                    languageCode: languageCode,
                    onAdd: { showingEditor = true }
                )
            } else {
                List {
                    Section {
                        ForEach(players) { player in
                            NavigationLink {
                                ManagedPlayerDetailView(
                                    player: player,
                                    languageCode: languageCode,
                                    knownTeams: knownTeams,
                                    currentTeamId: currentTeamId,
                                    onChanged: { await reload() },
                                    onOpenTeam: { openedTeam = $0 },
                                    onRevealCurrentTeam: onRevealCurrentTeam
                                )
                            } label: {
                                ManagedPlayerRow(player: player, languageCode: languageCode)
                            }
                        }
                    } footer: {
                        Text(L10n.t("managed_players_privacy_footer", languageCode: languageCode))
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await reload() }
            }
        }
        .navigationTitle(L10n.t("managed_players_title", languageCode: languageCode))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editingPlayer = nil
                    showingEditor = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("managed_players_add", languageCode: languageCode))
            }
        }
        .sheet(isPresented: $showingEditor) {
            NavigationStack {
                ManagedPlayerEditorSheet(
                    existing: editingPlayer,
                    languageCode: languageCode,
                    onSaved: { _ in await reload() }
                )
            }
        }
        .sheet(item: $openedTeam) { team in
            FanTeamDetailSheet(
                summary: team,
                mapViewModel: mapViewModel,
                chatViewModel: chatViewModel,
                onOpenChat: { context in
                    openedTeam = nil
                    dismiss()
                    onOpenTeamChat(context)
                },
                onTeamsChanged: onTeamsChanged,
                onTeamDeleted: {
                    openedTeam = nil
                    onTeamsChanged()
                }
            )
        }
        .alert(
            L10n.t("managed_players_error_title", languageCode: languageCode),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(L10n.t("OK", languageCode: languageCode), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: FanManagedPlayerChangeCenter.avatarDidChangeNotification)) { note in
            guard let change = FanManagedPlayerChangeCenter.avatarChange(from: note) else { return }
            applyLocalAvatarChange(change)
            Task { await reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: FanManagedPlayerChangeCenter.teamMembershipDidChangeNotification)) { note in
            guard FanManagedPlayerChangeCenter.teamMembershipChange(from: note) != nil else { return }
            Task { await reload() }
        }
    }

    private func applyLocalAvatarChange(_ change: FanManagedPlayerAvatarChange) {
        guard let idx = players.firstIndex(where: { $0.id == change.managedPlayerId }) else { return }
        var next = players
        next[idx] = next[idx].applyingAvatar(
            avatarURL: change.avatarURL,
            avatarThumbnailURL: change.avatarThumbnailURL
        )
        players = next
#if DEBUG
        ManagedPlayerAvatarDebug.log(
            "my_players_local_array_replaced",
            managedPlayerId: change.managedPlayerId,
            newAvatarURL: change.avatarURL,
            newThumbnailURL: change.avatarThumbnailURL,
            localArrayReplaced: true,
            refreshTriggered: true
        )
#endif
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            players = try await service.listMyManagedPlayers()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct MyPlayersEmptyStateView: View {
    let languageCode: String
    let onAdd: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "figure.and.child.holdinghands")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(FGColor.secondaryText(colorScheme))

            Text(L10n.t("managed_players_empty_title", languageCode: languageCode))
                .font(.headline)
                .foregroundStyle(FGColor.primaryText(colorScheme))

            Text(L10n.t("managed_players_empty_body", languageCode: languageCode))
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .padding(.horizontal, 32)

            Button(action: onAdd) {
                Text(L10n.t("managed_players_add", languageCode: languageCode))
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ManagedPlayerRow: View {
    let player: FanManagedPlayer
    let languageCode: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            ManagedPlayerAvatarView(
                managedPlayerId: player.id,
                avatarURL: player.avatarURL,
                avatarThumbnailURL: player.avatarThumbnailURL,
                displayName: player.displayName,
                size: 44
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(player.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))

                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let teams = FanManagedPlayerPresentation.teamCountCaption(
            player.teamCount,
            languageCode: languageCode
        )
        guard let born = FanManagedPlayerPresentation.birthYearCaption(
            player.birthYear,
            languageCode: languageCode
        ) else { return teams }
        return "\(born) · \(teams)"
    }
}

/// Managed players have no `user_profiles` row, so the avatar comes straight
/// from the player record (or initials) — never from a social identity.
struct ManagedPlayerAvatarView: View {
    var managedPlayerId: UUID? = nil
    let avatarURL: String?
    let avatarThumbnailURL: String?
    let displayName: String
    let size: CGFloat
    /// Optional bump after a successful upload when URL identity alone is insufficient.
    var avatarDisplayRefreshToken: UUID? = nil

    var body: some View {
        UserAvatarView(
            avatarThumbnailURL: avatarThumbnailURL,
            avatarURL: avatarURL ?? "",
            avatarDisplayRefreshToken: resolvedRefreshToken,
            displayName: displayName,
            email: "",
            size: size
        )
    }

    private var resolvedRefreshToken: UUID {
        if let avatarDisplayRefreshToken { return avatarDisplayRefreshToken }
        if let managedPlayerId {
            return UserAvatarView.stableRefreshToken(
                userId: managedPlayerId,
                thumbnailURL: avatarThumbnailURL,
                avatarURL: avatarURL
            )
        }
        return UserAvatarView.stableRefreshToken(
            userId: UserAvatarView.placeholderRefreshToken,
            thumbnailURL: avatarThumbnailURL,
            avatarURL: avatarURL
        )
    }
}

/// Roster avatar for either participant kind.
///
/// Authenticated members keep the shared social avatar renderer (presence rings,
/// profile cache). Managed players have no profile, so they render from the
/// roster row instead of a fabricated `UserPreview`.
struct TeamMemberAvatarView: View {
    let member: FanTeamMember
    let size: CGFloat

    var body: some View {
        if let preview = member.preview {
            SocialAvatarRenderer.socialAvatarView(for: preview, size: size)
        } else {
            ManagedPlayerAvatarView(
                managedPlayerId: member.managedPlayerId,
                avatarURL: member.avatarURL,
                avatarThumbnailURL: member.avatarThumbnailURL,
                displayName: member.displayName,
                size: size
            )
        }
    }
}

// MARK: - Create / edit

struct ManagedPlayerEditorSheet: View {
    let existing: FanManagedPlayer?
    let languageCode: String
    /// Called after a successful create/update with the player id.
    let onSaved: (_ managedPlayerId: UUID) async -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var preferredName = ""
    @State private var birthYear: Int?
    @State private var isSaving = false
    @State private var errorMessage: String?

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var pendingPhotoData: Data?
    @State private var localPreviewImage: UIImage?
    @State private var clearExistingAvatar = false
    @State private var isLoadingPhoto = false

    private let service = FanManagedPlayerService()

    private var canSave: Bool {
        !isSaving && !isLoadingPhoto && FanManagedPlayerValidation.canSubmit(
            firstName: firstName,
            lastName: lastName,
            birthYear: birthYear
        )
    }

    private var hasVisiblePhoto: Bool {
        if clearExistingAvatar { return localPreviewImage != nil || pendingPhotoData != nil }
        return localPreviewImage != nil
            || pendingPhotoData != nil
            || !(existing?.avatarURL ?? "").isEmpty
            || !(existing?.avatarThumbnailURL ?? "").isEmpty
    }

    var body: some View {
        Form {
            Section {
                ManagedPlayerPhotoEditorHeader(
                    languageCode: languageCode,
                    displayName: preferredName.isEmpty ? firstName : preferredName,
                    avatarURL: clearExistingAvatar ? nil : existing?.avatarURL,
                    avatarThumbnailURL: clearExistingAvatar ? nil : existing?.avatarThumbnailURL,
                    previewImage: localPreviewImage,
                    selectedPhotoItem: $selectedPhotoItem,
                    isBusy: isSaving || isLoadingPhoto,
                    hasPhoto: hasVisiblePhoto,
                    onRemove: hasVisiblePhoto ? { clearPhoto() } : nil
                )
            }

            Section {
                TextField(
                    L10n.t("managed_players_first_name", languageCode: languageCode),
                    text: $firstName
                )
                .textContentType(.givenName)

                TextField(
                    L10n.t("managed_players_last_name", languageCode: languageCode),
                    text: $lastName
                )
                .textContentType(.familyName)

                TextField(
                    L10n.t("managed_players_preferred_name", languageCode: languageCode),
                    text: $preferredName
                )
            } footer: {
                Text(L10n.t("managed_players_preferred_name_footer", languageCode: languageCode))
            }

            Section {
                ManagedPlayerBirthYearFormRow(
                    languageCode: languageCode,
                    birthYear: $birthYear
                )
            } footer: {
                Text(L10n.t("managed_players_birth_year_footer", languageCode: languageCode))
            }
        }
        .navigationTitle(
            L10n.t(
                existing == nil ? "managed_players_add" : "managed_players_edit",
                languageCode: languageCode
            )
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.t("Cancel", languageCode: languageCode)) { dismiss() }
                    .disabled(isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.t("Save", languageCode: languageCode)) {
                    Task { await save() }
                }
                .disabled(!canSave)
            }
        }
        .alert(
            L10n.t("managed_players_error_title", languageCode: languageCode),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(L10n.t("OK", languageCode: languageCode), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            guard let existing else { return }
            firstName = existing.firstName
            lastName = existing.lastName
            preferredName = existing.displayName
            birthYear = existing.birthYear
        }
        .onChange(of: selectedPhotoItem) { _, item in
            Task { await loadPickedPhoto(item) }
        }
    }

    private func clearPhoto() {
        pendingPhotoData = nil
        localPreviewImage = nil
        selectedPhotoItem = nil
        clearExistingAvatar = true
    }

    private func loadPickedPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        isLoadingPhoto = true
        defer { isLoadingPhoto = false }
        guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else {
            errorMessage = L10n.t("managed_players_photo_load_failed", languageCode: languageCode)
            return
        }
        pendingPhotoData = data
        localPreviewImage = UIImage(data: data)
        clearExistingAvatar = false
    }

    private func save() async {
        guard canSave else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let display = FanManagedPlayerValidation.resolvedDisplayName(
                firstName: firstName,
                lastName: lastName,
                preferred: preferredName
            )
            let playerId: UUID
            if let existing {
                playerId = existing.id
                try await service.updateManagedPlayer(
                    managedPlayerId: existing.id,
                    firstName: firstName,
                    lastName: lastName,
                    displayName: display,
                    birthYear: birthYear,
                    clearBirthYear: birthYear == nil
                )
            } else {
                playerId = try await service.createManagedPlayer(
                    firstName: firstName,
                    lastName: lastName,
                    displayName: preferredName,
                    birthYear: birthYear
                )
            }

            try await persistAvatarIfNeeded(for: playerId, existing: existing)
            await onSaved(playerId)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persistAvatarIfNeeded(for playerId: UUID, existing: FanManagedPlayer?) async throws {
        let previousFull = existing?.avatarURL
        let previousThumb = existing?.avatarThumbnailURL

        if let pendingPhotoData {
            let uploaded = try await service.uploadManagedPlayerAvatar(
                managedPlayerId: playerId,
                imageData: pendingPhotoData
            )
#if DEBUG
            ManagedPlayerAvatarDebug.log(
                "upload_succeeded",
                managedPlayerId: playerId,
                oldAvatarURL: previousFull,
                newAvatarURL: uploaded.fullURL,
                oldThumbnailURL: previousThumb,
                newThumbnailURL: uploaded.thumbnailURL,
                uploadSuccess: true
            )
#endif
            do {
                try await service.updateManagedPlayer(
                    managedPlayerId: playerId,
                    avatarURL: uploaded.fullURL,
                    avatarThumbnailURL: uploaded.thumbnailURL
                )
            } catch {
#if DEBUG
                ManagedPlayerAvatarDebug.log(
                    "db_update_failed_after_upload",
                    managedPlayerId: playerId,
                    oldAvatarURL: previousFull,
                    newAvatarURL: uploaded.fullURL,
                    oldThumbnailURL: previousThumb,
                    newThumbnailURL: uploaded.thumbnailURL,
                    uploadSuccess: true,
                    dbUpdateSuccess: false
                )
#endif
                throw error
            }
#if DEBUG
            ManagedPlayerAvatarDebug.log(
                "db_update_succeeded",
                managedPlayerId: playerId,
                oldAvatarURL: previousFull,
                newAvatarURL: uploaded.fullURL,
                oldThumbnailURL: previousThumb,
                newThumbnailURL: uploaded.thumbnailURL,
                uploadSuccess: true,
                dbUpdateSuccess: true
            )
#endif
            await service.deleteReplacedManagedPlayerAvatarIfNeeded(
                oldFullURL: previousFull,
                oldThumbnailURL: previousThumb,
                newFullURL: uploaded.fullURL,
                newThumbnailURL: uploaded.thumbnailURL
            )
            FanManagedPlayerChangeCenter.postAvatarChange(
                FanManagedPlayerAvatarChange(
                    managedPlayerId: playerId,
                    avatarURL: uploaded.fullURL,
                    avatarThumbnailURL: uploaded.thumbnailURL,
                    previousAvatarURL: previousFull,
                    previousAvatarThumbnailURL: previousThumb
                )
            )
            return
        }

        guard clearExistingAvatar, existing != nil else { return }
        do {
            try await service.updateManagedPlayer(
                managedPlayerId: playerId,
                clearAvatar: true
            )
        } catch {
#if DEBUG
            ManagedPlayerAvatarDebug.log(
                "db_clear_failed",
                managedPlayerId: playerId,
                oldAvatarURL: previousFull,
                newAvatarURL: nil,
                oldThumbnailURL: previousThumb,
                newThumbnailURL: nil,
                dbUpdateSuccess: false
            )
#endif
            throw error
        }
#if DEBUG
        ManagedPlayerAvatarDebug.log(
            "db_clear_succeeded",
            managedPlayerId: playerId,
            oldAvatarURL: previousFull,
            newAvatarURL: nil,
            oldThumbnailURL: previousThumb,
            newThumbnailURL: nil,
            dbUpdateSuccess: true
        )
#endif
        await service.deleteReplacedManagedPlayerAvatarIfNeeded(
            oldFullURL: previousFull,
            oldThumbnailURL: previousThumb,
            newFullURL: nil,
            newThumbnailURL: nil
        )
        FanManagedPlayerChangeCenter.postAvatarChange(
            FanManagedPlayerAvatarChange(
                managedPlayerId: playerId,
                avatarURL: nil,
                avatarThumbnailURL: nil,
                previousAvatarURL: previousFull,
                previousAvatarThumbnailURL: previousThumb
            )
        )
    }
}

private struct ManagedPlayerPhotoEditorHeader: View {
    let languageCode: String
    let displayName: String
    let avatarURL: String?
    let avatarThumbnailURL: String?
    let previewImage: UIImage?
    @Binding var selectedPhotoItem: PhotosPickerItem?
    let isBusy: Bool
    let hasPhoto: Bool
    let onRemove: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    private let avatarSize: CGFloat = 92

    var body: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let previewImage {
                        Image(uiImage: previewImage)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ManagedPlayerAvatarView(
                            avatarURL: avatarURL,
                            avatarThumbnailURL: avatarThumbnailURL,
                            displayName: displayName.isEmpty ? "P" : displayName,
                            size: avatarSize
                        )
                    }
                }
                .frame(width: avatarSize, height: avatarSize)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .strokeBorder(
                            FGColor.secondaryText(colorScheme).opacity(0.22),
                            lineWidth: 1
                        )
                )

                Image(systemName: "camera.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.accentColor))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5))
                    .offset(x: 2, y: 2)
                    .accessibilityHidden(true)
            }

            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                Text(
                    L10n.t(
                        hasPhoto ? "managed_players_change_photo" : "managed_players_add_photo",
                        languageCode: languageCode
                    )
                )
                .font(.subheadline.weight(.semibold))
            }
            .disabled(isBusy)
            .buttonStyle(.plain)
            .accessibilityLabel(
                L10n.t(
                    hasPhoto ? "managed_players_change_photo" : "managed_players_add_photo",
                    languageCode: languageCode
                )
            )

            if let onRemove, hasPhoto {
                Button(role: .destructive, action: onRemove) {
                    Text(L10n.t("managed_players_remove_photo", languageCode: languageCode))
                        .font(.footnote)
                }
                .disabled(isBusy)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .listRowBackground(Color.clear)
    }
}

// MARK: - Detail

struct ManagedPlayerDetailView: View {
    let player: FanManagedPlayer
    let languageCode: String
    let knownTeams: [FanTeamSummary]
    let currentTeamId: UUID?
    let onChanged: () async -> Void
    let onOpenTeam: (FanTeamSummary) -> Void
    let onRevealCurrentTeam: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var currentPlayer: FanManagedPlayer
    @State private var memberships: [FanManagedPlayerTeamMembership] = []
    @State private var teamsById: [UUID: FanTeamSummary] = [:]
    @State private var isLoading = true
    @State private var showingEditor = false
    @State private var showingArchiveConfirm = false
    @State private var errorMessage: String?
    @State private var openingMembershipId: UUID?

    private let service = FanManagedPlayerService()
    private let teamsService = FanTeamsService()

    init(
        player: FanManagedPlayer,
        languageCode: String,
        knownTeams: [FanTeamSummary] = [],
        currentTeamId: UUID? = nil,
        onChanged: @escaping () async -> Void,
        onOpenTeam: @escaping (FanTeamSummary) -> Void,
        onRevealCurrentTeam: (() -> Void)? = nil
    ) {
        self.player = player
        self.languageCode = languageCode
        self.knownTeams = knownTeams
        self.currentTeamId = currentTeamId
        self.onChanged = onChanged
        self.onOpenTeam = onOpenTeam
        self.onRevealCurrentTeam = onRevealCurrentTeam
        _currentPlayer = State(initialValue: player)
        var initialTeams: [UUID: FanTeamSummary] = [:]
        for team in knownTeams {
            initialTeams[team.id] = team
        }
        _teamsById = State(initialValue: initialTeams)
    }

    var body: some View {
        List {
            Section {
                ManagedPlayerProfileHeaderView(
                    player: currentPlayer,
                    teamCount: max(currentPlayer.teamCount, memberships.count),
                    languageCode: languageCode,
                    onChangePhoto: { showingEditor = true }
                )
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section(L10n.t("managed_players_player_info", languageCode: languageCode)) {
                LabeledContent(L10n.t("managed_players_preferred_name", languageCode: languageCode)) {
                    Text(currentPlayer.displayName)
                }
                LabeledContent(L10n.t("managed_players_birth_year", languageCode: languageCode)) {
                    Text(
                        currentPlayer.birthYear.map(String.init)
                            ?? L10n.t("fan_teams_not_set", languageCode: languageCode)
                    )
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
            }

            Section {
                if isLoading && memberships.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .listRowBackground(Color.clear)
                } else if memberships.isEmpty {
                    Text(L10n.t("managed_players_no_teams", languageCode: languageCode))
                        .font(.subheadline)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else {
                    ForEach(memberships) { membership in
                        ManagedPlayerTeamMembershipCard(
                            membership: membership,
                            languageCode: languageCode,
                            isOpening: openingMembershipId == membership.id,
                            action: { openTeam(membership) }
                        )
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
            } header: {
                Text(L10n.t("managed_players_teams_section", languageCode: languageCode))
            }

            Section {
                Button(role: .destructive) {
                    showingArchiveConfirm = true
                } label: {
                    Text(L10n.t("managed_players_archive", languageCode: languageCode))
                }
            } footer: {
                Text(L10n.t("managed_players_archive_footer", languageCode: languageCode))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(currentPlayer.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.t("Edit", languageCode: languageCode)) { showingEditor = true }
            }
        }
        .sheet(isPresented: $showingEditor) {
            NavigationStack {
                ManagedPlayerEditorSheet(
                    existing: currentPlayer,
                    languageCode: languageCode,
                    onSaved: { _ in
                        await refreshPlayer()
                        await onChanged()
                        await loadMemberships()
                    }
                )
            }
        }
        .confirmationDialog(
            L10n.t("managed_players_archive_confirm", languageCode: languageCode),
            isPresented: $showingArchiveConfirm,
            titleVisibility: .visible
        ) {
            Button(
                L10n.t("managed_players_archive", languageCode: languageCode),
                role: .destructive
            ) {
                Task { await archive() }
            }
            Button(L10n.t("Cancel", languageCode: languageCode), role: .cancel) {}
        }
        .alert(
            L10n.t("managed_players_error_title", languageCode: languageCode),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(L10n.t("OK", languageCode: languageCode), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task { await loadMemberships() }
        .onReceive(NotificationCenter.default.publisher(for: FanManagedPlayerChangeCenter.avatarDidChangeNotification)) { note in
            guard let change = FanManagedPlayerChangeCenter.avatarChange(from: note),
                  change.managedPlayerId == currentPlayer.id else { return }
            currentPlayer = currentPlayer.applyingAvatar(
                avatarURL: change.avatarURL,
                avatarThumbnailURL: change.avatarThumbnailURL
            )
            Task { await refreshPlayer() }
        }
        .onReceive(NotificationCenter.default.publisher(for: FanManagedPlayerChangeCenter.teamMembershipDidChangeNotification)) { note in
            guard let change = FanManagedPlayerChangeCenter.teamMembershipChange(from: note),
                  change.managedPlayerId == currentPlayer.id else { return }
            Task {
                await refreshPlayer()
                await loadMemberships()
                await onChanged()
            }
        }
    }

    private func loadMemberships() async {
        isLoading = true
        defer { isLoading = false }
        do {
            memberships = try await service.listTeamMemberships(managedPlayerId: currentPlayer.id)
            await refreshKnownTeams()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshKnownTeams() async {
        var map: [UUID: FanTeamSummary] = [:]
        for team in knownTeams {
            map[team.id] = team
        }
        if let listed = try? await teamsService.listMyTeams() {
            for team in listed {
                map[team.id] = team
            }
        }
        teamsById = map
    }

    private func openTeam(_ membership: FanManagedPlayerTeamMembership) {
        if membership.teamId == currentTeamId {
            onRevealCurrentTeam?()
            return
        }
        if let team = teamsById[membership.teamId] {
            onOpenTeam(team)
            return
        }
        openingMembershipId = membership.id
        Task {
            defer { openingMembershipId = nil }
            await refreshKnownTeams()
            if let team = teamsById[membership.teamId] {
                onOpenTeam(team)
            } else {
                errorMessage = L10n.t(
                    "managed_players_open_team_unavailable",
                    languageCode: languageCode
                )
            }
        }
    }

    private func refreshPlayer() async {
        if let refreshed = try? await service.listMyManagedPlayers()
            .first(where: { $0.id == currentPlayer.id }) {
            currentPlayer = refreshed
        }
    }

    private func archive() async {
        do {
            try await service.archiveManagedPlayer(managedPlayerId: currentPlayer.id)
            await onChanged()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Profile header

private struct ManagedPlayerProfileHeaderView: View {
    let player: FanManagedPlayer
    let teamCount: Int
    let languageCode: String
    let onChangePhoto: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var metaLine: String {
        var parts: [String] = []
        if let age = FanManagedPlayerPresentation.ageCaption(
            birthYear: player.birthYear,
            languageCode: languageCode
        ) {
            parts.append(age)
        }
        parts.append(FanManagedPlayerPresentation.teamCountCaption(teamCount, languageCode: languageCode))
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 14) {
            ManagedPlayerAvatarView(
                managedPlayerId: player.id,
                avatarURL: player.avatarURL,
                avatarThumbnailURL: player.avatarThumbnailURL,
                displayName: player.displayName,
                size: 112
            )
            .overlay(
                Circle()
                    .strokeBorder(
                        FGColor.secondaryText(colorScheme).opacity(0.18),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.08),
                radius: 10,
                x: 0,
                y: 4
            )

            VStack(spacing: 6) {
                Text(player.displayName)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)

                Text(metaLine)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }

            Button(action: onChangePhoto) {
                Text(L10n.t("managed_players_change_photo", languageCode: languageCode))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FGColor.accentGreen)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(player.displayName). \(metaLine)")
    }
}

// MARK: - Manage Player Teams membership card

/// Premium Team membership card: logo, name, role, privacy, jersey/position, member since, chevron.
private struct ManagedPlayerTeamMembershipCard: View {
    let membership: FanManagedPlayerTeamMembership
    let languageCode: String
    let isOpening: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var logoSize: CGFloat = 52

    private var resolvedLogoSize: CGFloat {
        min(56, max(48, logoSize))
    }

    private var role: FanTeamMemberRole {
        FanManagedPlayerPresentation.managedPlayerTeamRole
    }

    private var jersey: String? {
        FanManagedPlayerPresentation.jerseyLabel(membership.playerNumber)
    }

    private var position: String? {
        FanManagedPlayerPresentation.positionLabel(
            preferredPositionCode: membership.preferredPositionCode,
            sportToken: membership.sport,
            languageCode: languageCode
        )
    }

    private var memberSinceDate: String? {
        FanManagedPlayerPresentation.memberSinceMediumDate(
            membership.joinedAt,
            languageCode: languageCode
        )
    }

    private var sportLine: String {
        let sport = AppSportCatalog.displayLabel(forSportToken: membership.sport)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sport
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                FanTeamMarkView(
                    sport: membership.sport,
                    logoURL: membership.logoURL,
                    logoThumbnailURL: membership.logoThumbnailURL,
                    colorHex: membership.colorHex,
                    size: resolvedLogoSize,
                    preferDetailURL: false
                )

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(membership.teamName)
                                .font(.body.weight(.bold))
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)
                                .minimumScaleFactor(0.9)
                            if !sportLine.isEmpty {
                                Text(sportLine)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        if isOpening {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(FGColor.secondaryText(colorScheme).opacity(0.45))
                                .padding(.top, 4)
                                .accessibilityHidden(true)
                        }
                    }

                    membershipBadgesRow

                    if jersey != nil || position != nil {
                        Text(jerseyPositionLine)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                    }

                    if let memberSinceDate {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.t("managed_players_member_since_label", languageCode: languageCode))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .textCase(.uppercase)
                            Text(memberSinceDate)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(FGColor.cardBackground(colorScheme))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.55 : 0.7),
                        lineWidth: 1
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isOpening)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(cardAccessibilityLabel)
        .accessibilityHint(L10n.t("managed_players_open_team_a11y", languageCode: languageCode))
        .accessibilityAddTraits(.isButton)
    }

    private var jerseyPositionLine: String {
        [jersey, position].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private var membershipBadgesRow: some View {
        HStack(spacing: 6) {
            if FanManagedPlayerPresentation.showsPrivateTeamBadge {
                Text(L10n.t("fan_teams_private_team", languageCode: languageCode))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(FGColor.intentTeams)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        FGColor.intentTeams.opacity(colorScheme == .dark ? 0.22 : 0.12),
                        in: Capsule(style: .continuous)
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            HStack(spacing: 4) {
                Image(systemName: role.badgeSystemImage)
                    .font(.system(size: 9, weight: .bold))
                Text(L10n.t(role.localizedKey, languageCode: languageCode))
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(FGColor.secondaryText(colorScheme))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                FGColor.secondaryText(colorScheme).opacity(colorScheme == .dark ? 0.18 : 0.10),
                in: Capsule(style: .continuous)
            )

            Spacer(minLength: 0)
        }
    }

    private var cardAccessibilityLabel: String {
        var parts = [membership.teamName]
        if !sportLine.isEmpty { parts.append(sportLine) }
        if FanManagedPlayerPresentation.showsPrivateTeamBadge {
            parts.append(L10n.t("fan_teams_private_team", languageCode: languageCode))
        }
        parts.append(L10n.t(role.localizedKey, languageCode: languageCode))
        if !jerseyPositionLine.isEmpty { parts.append(jerseyPositionLine) }
        if let memberSinceDate {
            parts.append(
                "\(L10n.t("managed_players_member_since_label", languageCode: languageCode)) \(memberSinceDate)"
            )
        }
        return parts.joined(separator: ". ")
    }
}

// MARK: - Team Overview card

/// Shown on Team Overview **only** when the viewer guards a player on that Team.
struct TeamManagedPlayersCard: View {
    let seats: [FanTeamManagedPlayerSeat]
    let languageCode: String
    let onManage: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if seats.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L10n.t("managed_players_title", languageCode: languageCode))
                        .font(.footnote.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                    Spacer(minLength: 0)
                    Button(action: onManage) {
                        HStack(spacing: 2) {
                            Text(L10n.t("managed_players_manage", languageCode: languageCode))
                            Image(systemName: "chevron.right")
                        }
                        .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                }

                ForEach(seats) { seat in
                    HStack(spacing: 10) {
                        ManagedPlayerAvatarView(
                            managedPlayerId: seat.managedPlayerId,
                            avatarURL: seat.avatarURL,
                            avatarThumbnailURL: seat.avatarThumbnailURL,
                            displayName: seat.displayName,
                            size: 36
                        )
                        Text(seat.displayName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                        Spacer(minLength: 0)
                        if let number = seat.playerNumber, FanTeamPlayerNumber.isValid(number) {
                            Text(FanTeamPlayerNumber.displayLabel(number))
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                        }
                    }
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(FGAdaptiveSurface.cardElevated(colorScheme))
            )
        }
    }
}
