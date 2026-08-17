import SwiftUI

/// Invite Friends — Individuals (existing) + Teams (roster convenience → normal pickup invites).
struct PickupGameInviteFriendsSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let game: PickupGameRow

    @EnvironmentObject private var chatViewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @State private var mode: PickupInvitePickerMode = .individuals
    /// Selected invitee profile/auth user IDs only. Never conversation IDs.
    @State private var selectedInviteeUserIds: Set<UUID> = []
    @State private var selectedTeamIds: Set<UUID> = []
    @State private var manageableTeams: [FanTeamSummary] = []
    @State private var teamPreviewById: [UUID: PickupFanTeamInvitePreview] = [:]
    @State private var teamMemberIdsByTeamId: [UUID: [UUID]] = [:]
    @State private var teamSearchText = ""
    @State private var searchText = ""
    @State private var searchResults: [PickupInvitableFanSearchResult] = []
    @State private var inviteStatusByUserId: [UUID: String] = [:]
    @State private var searchTask: Task<Void, Never>?
    @State private var isSearching = false
    @State private var isLoadingTeams = false
    @State private var isSending = false
    @State private var errorText: String?
    @State private var showBulkConfirm = false
    @State private var expandedTeamExclusionId: UUID?

    private let teamsService = FanTeamsService()

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var eligibleFriends: [ChatViewModel.FriendDisplay] {
        var seenProfileIds = Set<UUID>()
        let sorted = chatViewModel.friends.sorted {
            $0.preview.displayName.localizedCaseInsensitiveCompare($1.preview.displayName) == .orderedAscending
        }
        var result: [ChatViewModel.FriendDisplay] = []
        result.reserveCapacity(sorted.count)
        for friend in sorted {
            let profileId = friend.preview.id
            guard profileId != viewModel.currentUserAuthId else { continue }
            guard !chatViewModel.isEitherDirectionBlocked(with: profileId) else { continue }
            guard seenProfileIds.insert(profileId).inserted else { continue }
            result.append(friend)
        }
        return result
    }

    private var filteredTeams: [FanTeamSummary] {
        let q = teamSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 1 else { return manageableTeams }
        return manageableTeams.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.sport.localizedCaseInsensitiveContains(q)
        }
    }

    private var effectiveSelectedCount: Int {
        selectedInviteeUserIds.count
    }

    private var canSend: Bool {
        !selectedInviteeUserIds.isEmpty && !isSending && game.isPickupGameInvitable()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                inviteHeader
                modePicker
                    .padding(.horizontal, FGSpacing.lg)
                    .padding(.bottom, FGSpacing.sm)

                Group {
                    switch mode {
                    case .individuals:
                        individualsList
                    case .teams:
                        teamsList
                    }
                }

                selectionFooter

                if let errorText, !errorText.isEmpty {
                    Text(errorText)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.dangerRed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, FGSpacing.lg)
                        .padding(.vertical, FGSpacing.sm)
                }
            }
            .fanGeoScreenBackground()
            .navigationTitle(L10n.t("Invite friends to play", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Close", languageCode: languageCode)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        if effectiveSelectedCount >= PickupInviteRecipientGate.bulkConfirmThreshold {
                            showBulkConfirm = true
                        } else {
                            Task { await sendInvites() }
                        }
                    } label: {
                        if isSending {
                            ProgressView()
                        } else {
                            Text(
                                PickupInviteRecipientGate.sendButtonTitle(
                                    count: effectiveSelectedCount,
                                    languageCode: languageCode
                                )
                            )
                        }
                    }
                    .disabled(!canSend)
                }
            }
            .confirmationDialog(
                String(
                    format: L10n.t("pickup_invite_bulk_confirm_title_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    Int64(effectiveSelectedCount)
                ),
                isPresented: $showBulkConfirm,
                titleVisibility: .visible
            ) {
                Button(L10n.t("pickup_invite_bulk_confirm_action", languageCode: languageCode)) {
                    Task { await sendInvites() }
                }
                Button(L10n.t("Cancel", languageCode: languageCode), role: .cancel) {}
            } message: {
                Text(
                    String(
                        format: L10n.t("pickup_invite_bulk_confirm_message_format", languageCode: languageCode),
                        locale: Locale(identifier: languageCode),
                        Int64(effectiveSelectedCount),
                        game.title
                    )
                )
            }
            .task {
                if chatViewModel.friends.isEmpty {
                    await chatViewModel.refresh()
                }
                inviteStatusByUserId = await viewModel.loadPickupInviteStatusesByInviteeUserId(gameId: game.id)
                await loadManageableTeams()
            }
            .onChange(of: searchText) { _, newValue in
                scheduleFanSearch(newValue)
            }
            .onDisappear {
                searchTask?.cancel()
            }
        }
    }

    private var modePicker: some View {
        Picker("", selection: $mode) {
            ForEach(PickupInvitePickerMode.allCases) { item in
                Text(L10n.t(item.localizedKey, languageCode: languageCode)).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel(L10n.t("pickup_invite_mode_a11y", languageCode: languageCode))
    }

    private var inviteHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                SportArtworkIconView(sport: game.sport, diameter: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(game.title)
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                    Text("\(game.sportIdentityLabel()) · \(game.gameFormat.displayTitle)")
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                    if let dateLine = game.pickupDateWithCompactTimeRange(languageCode: appLanguageRaw) {
                        Text(dateLine)
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                }
            }
            if !game.isPickupGameInvitable() {
                Text(L10n.t("pickup_invite_game_closed", languageCode: languageCode))
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(FGColor.dangerRed)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(FGSpacing.lg)
        .background(.ultraThinMaterial)
    }

    private var selectionFooter: some View {
        HStack {
            Text(
                String(
                    format: L10n.t("pickup_invite_selected_count_format", languageCode: languageCode),
                    locale: Locale(identifier: languageCode),
                    Int64(effectiveSelectedCount)
                )
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(FGColor.secondaryText(colorScheme))
            Spacer(minLength: 0)
            if !selectedTeamIds.isEmpty {
                Text(
                    String(
                        format: L10n.t("pickup_invite_teams_selected_format", languageCode: languageCode),
                        locale: Locale(identifier: languageCode),
                        Int64(selectedTeamIds.count)
                    )
                )
                .font(.caption2.weight(.medium))
                .foregroundStyle(FGColor.mutedText(colorScheme))
            }
        }
        .padding(.horizontal, FGSpacing.lg)
        .padding(.vertical, FGSpacing.sm)
        .background(.ultraThinMaterial)
    }

    private var individualsList: some View {
        List {
            Section {
                if eligibleFriends.isEmpty {
                    Text(L10n.t("pickup_invite_no_friends", languageCode: languageCode))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                } else {
                    ForEach(eligibleFriends) { friend in
                        pickupInviteFriendRow(friend)
                    }
                }
            } header: {
                Text(L10n.t("Friends", languageCode: languageCode))
            } footer: {
                Text(
                    String(
                        format: L10n.t("pickup_invite_capacity_footer_format", languageCode: languageCode),
                        locale: Locale(identifier: languageCode),
                        Int64(selectedInviteeUserIds.count),
                        Int64(PickupInviteRecipientGate.maxInviteesPerGame)
                    )
                )
            }

            Section {
                TextField(L10n.t("pickup_invite_search_placeholder", languageCode: languageCode), text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text(L10n.t("pickup_invite_non_friends_header", languageCode: languageCode))
            }

            Section {
                if isSearching {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(L10n.t("pickup_invite_searching", languageCode: languageCode))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                } else if searchText.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
                    Text(L10n.t("pickup_invite_search_hint", languageCode: languageCode))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                } else if searchResults.isEmpty {
                    Text(L10n.t("pickup_invite_no_fans_found", languageCode: languageCode))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                } else {
                    ForEach(searchResults) { result in
                        pickupInviteSearchResultRow(result)
                    }
                }
            } header: {
                Text(L10n.t("Search Results", languageCode: languageCode))
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var teamsList: some View {
        List {
            if manageableTeams.count > 3 {
                Section {
                    TextField(L10n.t("pickup_invite_team_search_placeholder", languageCode: languageCode), text: $teamSearchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }

            Section {
                if isLoadingTeams {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(L10n.t("pickup_invite_loading_teams", languageCode: languageCode))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                } else if manageableTeams.isEmpty {
                    Text(L10n.t("pickup_invite_no_manageable_teams", languageCode: languageCode))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                } else if filteredTeams.isEmpty {
                    Text(L10n.t("pickup_invite_no_teams_match", languageCode: languageCode))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                } else {
                    ForEach(filteredTeams) { team in
                        teamInviteRow(team)
                    }
                }
            } header: {
                Text(L10n.t("pickup_invite_mode_teams", languageCode: languageCode))
            } footer: {
                Text(L10n.t("pickup_invite_teams_footer", languageCode: languageCode))
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func teamInviteRow(_ team: FanTeamSummary) -> some View {
        let preview = teamPreviewById[team.id]
        let isSelected = selectedTeamIds.contains(team.id)
        let accent = Color(fanTeamHex: team.colorHex ?? "") ?? FGColor.accentGreen
        return Button {
            Task { await toggleTeamSelection(team) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                FanTeamMarkView(
                    sport: team.sport,
                    logoURL: team.logoURL,
                    logoThumbnailURL: team.logoThumbnailURL,
                    colorHex: team.colorHex,
                    size: 42
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(team.name)
                        .font(FGTypography.body.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                    Text(
                        FanTeamMetaLine.compose(
                            competitionLevel: team.competitionLevel,
                            sport: AppSportCatalog.displayLabel(forSportToken: team.sport),
                            memberCount: team.memberCount,
                            languageCode: languageCode
                        )
                    )
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    if let preview {
                        Text(
                            String(
                                format: L10n.t("pickup_invite_team_eligible_format", languageCode: languageCode),
                                locale: Locale(identifier: languageCode),
                                Int64(preview.eligibleCount),
                                Int64(preview.memberCountExcludingOrganizer)
                            )
                        )
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(accent)
                        if preview.hasExclusions {
                            Button {
                                expandedTeamExclusionId = expandedTeamExclusionId == team.id ? nil : team.id
                            } label: {
                                Text(L10n.t("pickup_invite_team_exclusions_toggle", languageCode: languageCode))
                                    .font(.caption2.weight(.medium))
                            }
                            .buttonStyle(.plain)
                            if expandedTeamExclusionId == team.id {
                                VStack(alignment: .leading, spacing: 2) {
                                    if preview.alreadyPlayingCount > 0 {
                                        Text("\(preview.alreadyPlayingCount) \(L10n.t("pickup_invite_excl_going", languageCode: languageCode))")
                                    }
                                    if preview.alreadyPendingCount > 0 {
                                        Text("\(preview.alreadyPendingCount) \(L10n.t("pickup_invite_excl_pending_join", languageCode: languageCode))")
                                    }
                                    if preview.alreadyInvitedCount > 0 {
                                        Text("\(preview.alreadyInvitedCount) \(L10n.t("pickup_invite_excl_invited", languageCode: languageCode))")
                                    }
                                    if preview.ineligibleCount > 0 {
                                        Text("\(preview.ineligibleCount) \(L10n.t("pickup_invite_excl_ineligible", languageCode: languageCode))")
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(FGColor.mutedText(colorScheme))
                            }
                        }
                    } else {
                        Text(L10n.t("pickup_invite_entire_team", languageCode: languageCode))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(FGColor.mutedText(colorScheme))
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? accent : FGColor.mutedText(colorScheme))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(team.name)
        .accessibilityValue(
            isSelected
                ? L10n.t("Selected", languageCode: languageCode)
                : L10n.t("Not selected", languageCode: languageCode)
        )
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private func pickupInviteFriendRow(_ friend: ChatViewModel.FriendDisplay) -> some View {
        let profileId = friend.preview.id
        let inviteStatus = inviteStatusByUserId[profileId]
        let disabled = inviteStatus != nil
        let isSelected = selectedInviteeUserIds.contains(profileId)
        return Button {
            toggleInviteeUserId(profileId)
        } label: {
            HStack(spacing: 12) {
                ProfileAvatarView(preview: friend.preview, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(friend.preview.displayName)
                        .font(FGTypography.body.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    if let username = friend.preview.username, !username.isEmpty {
                        Text("@\(username)")
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                    if let inviteStatus {
                        pickupInviteStatusBadge(status: inviteStatus)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: disabled ? "checkmark.seal.fill" : (isSelected ? "checkmark.circle.fill" : "circle"))
                    .font(.title3)
                    .foregroundStyle(disabled ? Color.orange : (isSelected ? FGColor.accentGreen : FGColor.mutedText(colorScheme)))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.62 : 1)
    }

    private func pickupInviteSearchResultRow(_ result: PickupInvitableFanSearchResult) -> some View {
        let profileId = result.user_id
        let inviteStatus = inviteStatusByUserId[profileId]
        let disabled = inviteStatus != nil
        let isSelected = selectedInviteeUserIds.contains(profileId)
        return Button {
            toggleSearchResult(result)
        } label: {
            HStack(spacing: 12) {
                ProfileAvatarView(preview: result.userPreview, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(result.display_name)
                            .font(FGTypography.body.weight(.semibold))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                        if result.is_friend {
                            Text(L10n.t("Friend", languageCode: languageCode))
                                .font(FGTypography.caption.weight(.bold))
                                .foregroundStyle(FGColor.accentGreen)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(FGColor.accentGreen.opacity(0.12), in: Capsule())
                        }
                    }
                    if !result.displayHandle.isEmpty {
                        Text(result.displayHandle)
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                    if let inviteStatus {
                        pickupInviteStatusBadge(status: inviteStatus)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: disabled ? "checkmark.seal.fill" : (isSelected ? "checkmark.circle.fill" : "circle"))
                    .font(.title3)
                    .foregroundStyle(disabled ? Color.orange : (isSelected ? FGColor.accentGreen : FGColor.mutedText(colorScheme)))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.62 : 1)
    }

    private func toggleInviteeUserId(_ profileUserId: UUID) {
        guard inviteStatusByUserId[profileUserId] == nil else { return }
        if selectedInviteeUserIds.contains(profileUserId) {
            selectedInviteeUserIds.remove(profileUserId)
            // Deselect teams that contributed this user only if no longer covered — keep simple: leave team selection.
        } else if selectedInviteeUserIds.count < PickupInviteRecipientGate.maxInviteesPerGame {
            selectedInviteeUserIds.insert(profileUserId)
        } else {
            errorText = L10n.t("pickup_invite_capacity_error", languageCode: languageCode)
        }
    }

    private func toggleSearchResult(_ result: PickupInvitableFanSearchResult) {
        let profileId = result.user_id
        guard inviteStatusByUserId[profileId] == nil else { return }
        toggleInviteeUserId(profileId)
    }

    @MainActor
    private func toggleTeamSelection(_ team: FanTeamSummary) async {
        errorText = nil
        if selectedTeamIds.contains(team.id) {
            selectedTeamIds.remove(team.id)
            if let memberIds = teamMemberIdsByTeamId[team.id] {
                // Remove members that aren't covered by another selected team or explicit individual intent.
                // Keep members still present in other selected teams.
                var coveredByOtherTeams = Set<UUID>()
                for otherId in selectedTeamIds {
                    coveredByOtherTeams.formUnion(teamMemberIdsByTeamId[otherId] ?? [])
                }
                for mid in memberIds where !coveredByOtherTeams.contains(mid) {
                    selectedInviteeUserIds.remove(mid)
                }
            }
            return
        }

        do {
            if teamPreviewById[team.id] == nil {
                teamPreviewById[team.id] = try await teamsService.previewPickupInvite(
                    teamId: team.id,
                    pickupGameId: game.id
                )
            }
            if teamMemberIdsByTeamId[team.id] == nil {
                let members = try await teamsService.listMembers(teamId: team.id)
                // Managed players have no account to invite to a pickup game.
                teamMemberIdsByTeamId[team.id] = members.compactMap(\.userId)
            }
            let candidateIds = teamMemberIdsByTeamId[team.id] ?? []
            let result = PickupInviteRecipientGate.selectableUserIds(
                candidateIds: candidateIds,
                organizerId: viewModel.currentUserAuthId,
                gateByUserId: inviteStatusByUserId,
                alreadySelected: selectedInviteeUserIds
            )
            for id in result.added {
                selectedInviteeUserIds.insert(id)
            }
            selectedTeamIds.insert(team.id)
            if result.added.isEmpty, (teamPreviewById[team.id]?.eligibleCount ?? 0) == 0 {
                errorText = L10n.t("pickup_invite_team_none_eligible", languageCode: languageCode)
            } else if result.skippedCapacity > 0 {
                errorText = L10n.t("pickup_invite_capacity_error", languageCode: languageCode)
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func pickupInviteStatusBadge(status: String) -> some View {
        let display = pickupInviteStatusDisplay(status)
        return Text(display.title)
            .font(FGTypography.caption.weight(.semibold))
            .foregroundStyle(display.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(display.tint.opacity(colorScheme == .dark ? 0.18 : 0.11), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(display.tint.opacity(colorScheme == .dark ? 0.26 : 0.18), lineWidth: 0.8)
            }
    }

    private func pickupInviteStatusDisplay(_ status: String) -> (title: String, tint: Color) {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pending":
            return (L10n.t("pickup_invite_status_pending", languageCode: languageCode), FGColor.secondaryText(colorScheme))
        case "accepted":
            return (L10n.t("Accepted", languageCode: languageCode), FGColor.accentGreen)
        case "maybe":
            return (L10n.t("Maybe", languageCode: languageCode), Color.orange)
        case "declined":
            return (L10n.t("Declined", languageCode: languageCode), colorScheme == .dark ? Color.red.opacity(0.74) : Color.red.opacity(0.68))
        case "going":
            return (L10n.t("pickup_invite_status_going", languageCode: languageCode), FGColor.accentGreen)
        case "join_pending":
            return (L10n.t("pickup_invite_status_join_pending", languageCode: languageCode), Color.orange)
        default:
            return (L10n.t("pickup_invite_status_already", languageCode: languageCode), Color.orange)
        }
    }

    private func scheduleFanSearch(_ raw: String) {
        searchTask?.cancel()
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            isSearching = false
            searchResults = []
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            let results = await viewModel.searchPickupInvitableFans(query: trimmed, limit: 20)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                searchResults = results
                isSearching = false
            }
        }
    }

    @MainActor
    private func loadManageableTeams() async {
        isLoadingTeams = true
        defer { isLoadingTeams = false }
        do {
            manageableTeams = try await teamsService.listManageableTeamsForPickupInvite()
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
#if DEBUG
            print("[PickupInviteDebug] loadTeams failed \(error.localizedDescription)")
#endif
            manageableTeams = []
        }
    }

    private func sendInvites() async {
        guard canSend else { return }
        isSending = true
        errorText = nil
        defer { isSending = false }

        var results: [PickupGameInviteCreateResult] = []

        // Preferred secure path for Teams: server resolves roster.
        if !selectedTeamIds.isEmpty {
            let teamRows = await viewModel.createPickupGameInvitesFromFanTeams(
                game: game,
                teamIds: Array(selectedTeamIds),
                showsToast: false
            )
            results.append(contentsOf: teamRows)
        }

        // Individuals not already covered by team invite outcomes.
        let covered = Set(results.map(\.invitee_user_id))
        let leftoverIndividuals = selectedInviteeUserIds.filter { !covered.contains($0) }
        if !leftoverIndividuals.isEmpty {
            let individualRows = await viewModel.createPickupGameInvites(
                game: game,
                inviteeUserIds: Array(leftoverIndividuals),
                message: nil,
                showsToast: false
            )
            results.append(contentsOf: individualRows)
        }

        let created = results.filter { $0.outcome == "created" }.count
        let ineligible = results.filter { $0.outcome != "created" }.count
        let softOk = results.contains { ["duplicate", "already_playing", "already_pending"].contains($0.outcome) }
#if DEBUG
        print("[PickupInviteDebug] sendUI created=\(created) totalOutcomes=\(results.count) teams=\(selectedTeamIds.count)")
#endif
        if created > 0 {
            var message = "Sent \(created) invite\(created == 1 ? "" : "s")."
            if ineligible > 0 {
                message += " \(ineligible) already participating or ineligible."
            }
            viewModel.showSocialActionToast(message, isError: false)
            await viewModel.loadPickupGameRoster(pickupGameId: game.id, force: true)
            dismiss()
        } else if softOk {
            viewModel.showSocialActionToast("Those fans were already invited.", isError: false)
            dismiss()
        } else {
            errorText = L10n.t("pickup_invite_none_sent", languageCode: languageCode)
        }
    }
}
