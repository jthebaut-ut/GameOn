import SwiftUI

// MARK: - Detail section (Team-linked events only)

enum FanTeamEventLineupDetailPresentationStyle: Equatable, Sendable {
    /// Standard compact card (starting/bench preview counts).
    case standard
    /// Parent/player-first: published status + current player line + View.
    case playerParent
}

/// Compact Lineup entry on Team event detail. Leaf navigation via sheets — not inlined into Discover.
struct FanTeamEventLineupDetailSection: View {
    let context: FanTeamEventLineupContext
    @ObservedObject var viewModel: MapViewModel
    var presentationStyle: FanTeamEventLineupDetailPresentationStyle = .standard

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @State private var lineup: FanTeamEventLineup?
    @State private var teamMembers: [FanTeamMember] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var accessDenied = false
    @State private var showEditor = false
    @State private var showPublished = false
    @State private var openEditorAfterPublishedDismiss = false

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    /// Stable FanGeo lineup blue — never Team `colorHex`.
    private var accent: Color { FanTeamLineupAppearance.accent }

    private var supportsSoccerFormation: Bool {
        let token = AppSportCatalog.canonicalFormPickerToken(for: context.sportToken).lowercased()
        return token == "soccer" || token == "football soccer"
    }

    /// Keyed by roster-seat participant key: the account id, or the managed player
    /// id for a guardian-managed seat (20260961).
    private var teamById: [UUID: FanTeamMember] {
        Dictionary(
            uniqueKeysWithValues: teamMembers.compactMap { member in
                member.participantKey.map { ($0, member) }
            }
        )
    }

    private var attendanceById: [UUID: PickupDetailAttendanceCategory] {
        guard let roster = viewModel.pickupGameRosterByGameId[context.pickupGameId] else { return [:] }
        var map: [UUID: PickupDetailAttendanceCategory] = [:]
        for row in PickupTeamAttendancePresentation.rows(from: roster) {
            map[row.id] = row.category
        }
        return map
    }

    private var rosterById: [UUID: PickupGameRosterMember] {
        guard let roster = viewModel.pickupGameRosterByGameId[context.pickupGameId] else { return [:] }
        var map: [UUID: PickupGameRosterMember] = [:]
        for row in PickupTeamAttendancePresentation.rows(from: roster) {
            map[row.id] = row.member
        }
        return map
    }

    var body: some View {
        Group {
            if accessDenied {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: FGSpacing.sm) {
                    HStack {
                        Text(L10n.t("fan_team_lineup_title", languageCode: languageCode))
                            .font(FGTypography.caption.weight(.bold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .textCase(.uppercase)
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 0)
                        if let lineup,
                           lineup.viewerCanManage,
                           lineup.exists,
                           !context.isEventCancelled {
                            Button {
                                showPublished = true
                            } label: {
                                Text(L10n.t("Edit", languageCode: languageCode))
                                    .font(FGTypography.caption.weight(.bold))
                                    .foregroundStyle(accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if let loadError, !loadError.isEmpty, lineup == nil, !isLoading {
                        Text(loadError)
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.dangerRed)
                    } else if let lineup {
                        compactCard(for: lineup)
                    } else if isLoading {
                        emptyLineupCard(isLoading: true, canManage: false)
                    } else {
                        emptyLineupCard(isLoading: false, canManage: false)
                    }
                }
            }
        }
        .task(id: context.pickupGameId) {
            await reload()
        }
        .sheet(isPresented: $showEditor, onDismiss: {
            Task { await reload() }
        }) {
            FanTeamEventLineupEditorView(context: context, viewModel: viewModel)
        }
        .sheet(isPresented: $showPublished, onDismiss: {
            Task { await reload() }
            if openEditorAfterPublishedDismiss {
                openEditorAfterPublishedDismiss = false
                showEditor = true
            }
        }) {
            FanTeamEventLineupPublishedView(
                context: context,
                viewModel: viewModel,
                onRequestEdit: {
                    openEditorAfterPublishedDismiss = true
                    showPublished = false
                }
            )
        }
    }

    @ViewBuilder
    private func compactCard(for lineup: FanTeamEventLineup) -> some View {
        let canManage = lineup.viewerCanManage
        let published = lineup.isPublished
        let draft = lineup.isDraft

        if published || (draft && canManage) {
            Group {
                if presentationStyle == .playerParent {
                    playerParentCompactCard(lineup: lineup)
                } else {
                    Button {
                        // One affordance: open Lineup. Edit lives inside for staff.
                        showPublished = true
                    } label: {
                        compactCardBody(lineup: lineup, canManage: canManage)
                    }
                    .buttonStyle(.plain)
                    .fanGeoGlassCard(cornerRadius: 16)
                }
            }
        } else if canManage, !context.isEventCancelled, !lineup.exists {
            emptyLineupCard(isLoading: false, canManage: true)
        } else {
            // Members (or cancelled): intentional empty state — never a blank hole.
            emptyLineupCard(isLoading: false, canManage: false)
        }
    }

    private func emptyLineupCard(isLoading: Bool, canManage: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Text(L10n.t("fan_team_lineup_not_published_yet", languageCode: languageCode))
                .font(FGTypography.metadata.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            if canManage, !context.isEventCancelled {
                Button {
                    showEditor = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.caption.weight(.bold))
                        Text(L10n.t("fan_team_lineup_create", languageCode: languageCode))
                            .font(FGTypography.caption.weight(.bold))
                    }
                    .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(FGSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fanGeoGlassCard(cornerRadius: 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [
                L10n.t("fan_team_lineup_title", languageCode: languageCode),
                L10n.t("fan_team_lineup_not_published_yet", languageCode: languageCode)
            ].joined(separator: ". ")
        )
    }

    /// Player/parent event-detail card: status + position chips + View Lineup.
    private func playerParentCompactCard(lineup: FanTeamEventLineup) -> some View {
        let ordered = FanTeamLineupPresentation.playerParentOrderedPlayers(
            from: lineup,
            sportToken: context.sportToken,
            teamMembersById: teamById,
            attendanceById: attendanceById,
            rosterMembersById: rosterById,
            currentUserId: viewModel.currentUserAuthId
        )
        let me = ordered.first { FanTeamLineupPresentation.isHighlightedForViewer($0) }
        let statusKey = lineup.status?.shortLocalizedKey ?? "fan_team_lineup_status_draft"
        let statusColor = FanTeamLineupAppearance.statusAccent(isPublished: lineup.isPublished)
        let preview = Array(ordered.prefix(6))
        let overflow = max(0, ordered.count - preview.count)
        let playerLine: String? = {
            guard let me else { return nil }
            var parts: [String] = [me.displayName]
            if me.lineupStatus == .bench {
                parts.append(L10n.t("fan_team_lineup_substitute", languageCode: languageCode))
            } else if let pos = FanTeamLineupPresentation.displayPositionCode(
                positionCode: me.positionCode,
                sportToken: context.sportToken
            ) {
                parts.append(pos)
            }
            return parts.joined(separator: " · ")
        }()

        return Button {
            // One affordance on the Event card — Edit lives inside Lineup for staff.
            showPublished = true
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Text(L10n.t(statusKey, languageCode: languageCode))
                                .font(FGTypography.caption.weight(.bold))
                                .foregroundStyle(statusColor)
                            if lineup.isPublished {
                                Image(systemName: "checkmark")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(statusColor)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill(FanTeamLineupAppearance.softFill(colorScheme, accent: statusColor))
                        )

                        if let playerLine {
                            Text(playerLine)
                                .font(FGTypography.metadata.weight(.semibold))
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)
                                .multilineTextAlignment(.leading)
                            Text(L10n.t("fan_team_lineup_your_position", languageCode: languageCode))
                                .font(FGTypography.caption.weight(.medium))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                        } else if lineup.isPublished {
                            Text(
                                String(
                                    format: L10n.t(
                                        "fan_team_lineup_player_count_format",
                                        languageCode: languageCode
                                    ),
                                    locale: Locale(identifier: languageCode),
                                    Int64(ordered.count)
                                )
                            )
                            .font(FGTypography.caption.weight(.medium))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 4) {
                        Text(L10n.t("fan_team_lineup_view", languageCode: languageCode))
                            .font(FGTypography.caption.weight(.bold))
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(accent)
                    .fixedSize(horizontal: true, vertical: false)
                }

                if !preview.isEmpty {
                    HStack(spacing: -6) {
                        ForEach(preview) { player in
                            lineupPreviewChip(for: player)
                        }
                        if overflow > 0 {
                            Text(
                                String(
                                    format: L10n.t(
                                        "fan_team_lineup_more_format",
                                        languageCode: languageCode
                                    ),
                                    locale: Locale(identifier: languageCode),
                                    Int64(overflow)
                                )
                            )
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 10)
                            .frame(height: 36)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(accent.opacity(colorScheme == .dark ? 0.22 : 0.12))
                            )
                            .padding(.leading, 8)
                        }
                    }
                    .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .padding(FGSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fanGeoGlassCard(cornerRadius: 16)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            [
                L10n.t("fan_team_lineup_title", languageCode: languageCode),
                L10n.t(statusKey, languageCode: languageCode),
                playerLine,
                playerLine == nil
                    ? nil
                    : L10n.t("fan_team_lineup_your_position", languageCode: languageCode)
            ]
            .compactMap { $0 }
            .joined(separator: ". ")
        )
        .accessibilityHint(L10n.t("fan_team_lineup_view", languageCode: languageCode))
    }

    private func lineupPreviewChip(for player: FanTeamLineupPlayerPresentation) -> some View {
        let badge = FanTeamLineupPresentation.playerParentPositionBadge(
            player: player,
            sportToken: context.sportToken,
            languageCode: languageCode
        )
        return Text(badge)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(accent)
            .frame(width: 36, height: 36)
            .background(
                Circle()
                    .fill(accent.opacity(colorScheme == .dark ? 0.22 : 0.12))
            )
            .overlay(
                Circle()
                    .strokeBorder(
                        colorScheme == .dark ? Color.black.opacity(0.35) : Color.white,
                        lineWidth: 1.5
                    )
            )
    }

    private func compactCardBody(lineup: FanTeamEventLineup, canManage: Bool) -> some View {
        let preview = FanTeamLineupPresentation.compactPreviewPlayers(
            from: lineup,
            teamMembersById: teamById,
            attendanceById: attendanceById,
            rosterMembersById: rosterById,
            currentUserId: viewModel.currentUserAuthId
        )
        let startingCount = lineup.starting.count
        let benchCount = lineup.bench.count
        let statusKey = lineup.status?.shortLocalizedKey ?? "fan_team_lineup_status_draft"
        let statusColor = FanTeamLineupAppearance.statusAccent(isPublished: lineup.isPublished)
        let countsLine = String(
            format: L10n.t("fan_team_lineup_counts_format", languageCode: languageCode),
            locale: Locale(identifier: languageCode),
            Int64(startingCount),
            Int64(benchCount)
        )

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text(L10n.t(statusKey, languageCode: languageCode))
                    .font(FGTypography.caption.weight(.bold))
                    .foregroundStyle(statusColor)
                if lineup.isPublished {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
            }

            Text(countsLine)
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))

            if supportsSoccerFormation,
               let formation = lineup.formation?.trimmingCharacters(in: .whitespacesAndNewlines),
               !formation.isEmpty {
                Text(formation)
                    .font(FGTypography.caption.weight(.medium))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }

            if !preview.visible.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(preview.visible) { player in
                        FanTeamEventLineupCompactPlayerRow(
                            player: player,
                            sportToken: context.sportToken,
                            languageCode: languageCode,
                            accent: accent
                        )
                    }
                    if preview.hiddenCount > 0 {
                        Text(
                            String(
                                format: L10n.t("fan_team_lineup_more_format", languageCode: languageCode),
                                locale: Locale(identifier: languageCode),
                                Int64(preview.hiddenCount)
                            )
                        )
                        .font(FGTypography.caption.weight(.medium))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                }
            }

            if let warningCount = warningCount(for: lineup), warningCount > 0, canManage {
                Text(
                    String(
                        format: L10n.t("fan_team_lineup_no_longer_attending_count_format", languageCode: languageCode),
                        locale: Locale(identifier: languageCode),
                        Int64(warningCount)
                    )
                )
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.dangerRed)
            }

            HStack(spacing: 4) {
                Text(L10n.t("fan_team_lineup_view", languageCode: languageCode))
                    .font(FGTypography.caption.weight(.semibold))
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(accent)
            .padding(.top, 2)
        }
        .padding(FGSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(compactAccessibilityLabel(lineup: lineup, countsLine: countsLine))
        .accessibilityHint(L10n.t("fan_team_lineup_view", languageCode: languageCode))
    }

    private func compactAccessibilityLabel(lineup: FanTeamEventLineup, countsLine: String) -> String {
        var parts = [
            L10n.t("fan_team_lineup_title", languageCode: languageCode),
            L10n.t(lineup.status?.shortLocalizedKey ?? "fan_team_lineup_status_draft", languageCode: languageCode),
            countsLine
        ]
        if supportsSoccerFormation,
           let formation = lineup.formation?.trimmingCharacters(in: .whitespacesAndNewlines),
           !formation.isEmpty {
            parts.append("\(L10n.t("fan_team_lineup_formation", languageCode: languageCode)) \(formation)")
        }
        return parts.joined(separator: ", ")
    }

    private func warningCount(for lineup: FanTeamEventLineup) -> Int? {
        guard lineup.exists else { return nil }
        let count = FanTeamLineupPresentation.noLongerAttendingCount(
            members: lineup.members,
            attendanceById: attendanceById
        )
        return count > 0 ? count : nil
    }

    private func reload() async {
        isLoading = true
        loadError = nil
        accessDenied = false
        defer { isLoading = false }
        do {
            async let lineupTask = FanTeamEventLineupService().getLineup(
                pickupGameId: context.pickupGameId,
                teamId: context.teamId
            )
            async let membersTask = FanTeamsService().listMembers(teamId: context.teamId)
            await viewModel.loadPickupGameRoster(pickupGameId: context.pickupGameId, force: false)
            let (loaded, members) = try await (lineupTask, membersTask)
            lineup = loaded
            teamMembers = members
        } catch {
            lineup = nil
            teamMembers = []
            loadError = nil
            accessDenied = true
#if DEBUG
            print("[FanTeamLineup] detailLoad failed error=\(error.localizedDescription)")
#endif
        }
    }
}

/// Compact scannable row for event-detail preview (no nested buttons).
private struct FanTeamEventLineupCompactPlayerRow: View {
    let player: FanTeamLineupPlayerPresentation
    let sportToken: String
    let languageCode: String
    let accent: Color

    @Environment(\.colorScheme) private var colorScheme

    private var positionLabel: String? {
        FanTeamLineupPresentation.displayPositionCode(
            positionCode: player.positionCode,
            sportToken: sportToken
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            if let number = player.numberLabel {
                Text(number)
                    .font(FGTypography.caption.weight(.bold))
                    .foregroundStyle(accent)
                    .frame(minWidth: 28, alignment: .leading)
            }
            Text(player.displayName)
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            if let positionLabel {
                Text(positionLabel)
                    .font(FGTypography.caption.weight(.bold))
                    .foregroundStyle(accent)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            FanTeamLineupPresentation.accessibilityRowLabel(
                player: player,
                sportToken: sportToken,
                languageCode: languageCode
            )
        )
    }
}

// MARK: - Editor (parent-friendly manager UI)

struct FanTeamEventLineupEditorView: View {
    let context: FanTeamEventLineupContext
    @ObservedObject var viewModel: MapViewModel

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @State private var members: [FanTeamLineupMemberDraft] = []
    /// Preserved for backend compatibility; not shown in the manager UI.
    @State private var formation: String = ""
    @State private var teamMembers: [FanTeamMember] = []
    @State private var viewerCanManage = false
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorText: String?
    @State private var editingParticipantKey: UUID?

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var sportToken: String { context.sportToken }

    private var supportsPositions: Bool {
        FanTeamSportPositions.supportsPositions(forSportToken: sportToken)
    }

    private var accent: Color { FanTeamLineupAppearance.accent }

    /// Keyed by roster-seat participant key: the account id, or the managed player
    /// id for a guardian-managed seat (20260961).
    private var teamById: [UUID: FanTeamMember] {
        Dictionary(
            uniqueKeysWithValues: teamMembers.compactMap { member in
                member.participantKey.map { ($0, member) }
            }
        )
    }

    private var attendanceById: [UUID: PickupDetailAttendanceCategory] {
        guard let roster = viewModel.pickupGameRosterByGameId[context.pickupGameId] else { return [:] }
        var map: [UUID: PickupDetailAttendanceCategory] = [:]
        for row in PickupTeamAttendancePresentation.rows(from: roster) {
            map[row.id] = row.category
        }
        return map
    }

    private var rosterById: [UUID: PickupGameRosterMember] {
        guard let roster = viewModel.pickupGameRosterByGameId[context.pickupGameId] else { return [:] }
        var map: [UUID: PickupGameRosterMember] = [:]
        for row in PickupTeamAttendancePresentation.rows(from: roster) {
            map[row.id] = row.member
        }
        return map
    }

    /// One alphabetical list of every roster member in the draft.
    /// Playing Today = `.starting`; Not Playing = `.bench` (existing storage).
    private var rosterRows: [FanTeamLineupPlayerPresentation] {
        FanTeamLineupPresentation.project(
            members: members,
            teamMembersById: teamById,
            attendanceById: attendanceById,
            rosterMembersById: rosterById,
            currentUserId: viewModel.currentUserAuthId
        )
        .sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private var editingPlayer: FanTeamLineupPlayerPresentation? {
        guard let editingParticipantKey else { return nil }
        return rosterRows.first(where: { $0.participantKey == editingParticipantKey })
    }

    private var noLongerAttending: Int {
        FanTeamLineupPresentation.noLongerAttendingCount(members: members, attendanceById: attendanceById)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    editorList
                }
            }
            .fanGeoScreenBackground()
            .navigationTitle(L10n.t("fan_team_lineup_title", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Close", languageCode: languageCode)) { dismiss() }
                }
            }
            .task {
                await bootstrap()
            }
            .sheet(item: Binding(
                get: { editingPlayer },
                set: { editingParticipantKey = $0?.participantKey }
            )) { player in
                FanTeamEventLineupPlayerQuickEditSheet(
                    player: player,
                    sportToken: sportToken,
                    languageCode: languageCode,
                    accent: accent,
                    supportsPositions: supportsPositions,
                    teamDefaultPositionCode: teamById[player.participantKey]?.preferredPositionCode,
                    onSave: { playingToday, positionCode in
                        applyPlayerEdit(
                            participantKey: player.participantKey,
                            playingToday: playingToday,
                            positionCode: positionCode
                        )
                    }
                )
            }
            .safeAreaInset(edge: .bottom) {
                if viewerCanManage, !context.isEventCancelled {
                    bottomBar
                }
            }
        }
    }

    private var editorList: some View {
        List {
            Section {
                eventHeader
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

            if noLongerAttending > 0 {
                Section {
                    Text(
                        String(
                            format: L10n.t(
                                "fan_team_lineup_no_longer_attending_count_format",
                                languageCode: languageCode
                            ),
                            locale: Locale(identifier: languageCode),
                            Int64(noLongerAttending)
                        )
                    )
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(FGColor.dangerRed)
                }
            }

            Section {
                if rosterRows.isEmpty {
                    Text(L10n.t("fan_team_lineup_no_roster_members", languageCode: languageCode))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                } else {
                    ForEach(rosterRows) { row in
                        FanTeamEventLineupManagerRosterRow(
                            player: row,
                            sportToken: sportToken,
                            languageCode: languageCode,
                            accent: accent,
                            onTap: {
                                guard viewerCanManage, !context.isEventCancelled else { return }
                                editingParticipantKey = row.participantKey
                            }
                        )
                        .listRowBackground(Color.clear)
                        .disabled(!viewerCanManage || context.isEventCancelled || isSaving)
                    }
                }
            } header: {
                Text(L10n.t("fan_team_lineup_roster_section", languageCode: languageCode))
                    .accessibilityAddTraits(.isHeader)
            } footer: {
                Text(L10n.t("fan_team_lineup_manager_help", languageCode: languageCode))
                    .font(.footnote)
            }

            if let errorText, !errorText.isEmpty {
                Section {
                    Text(errorText)
                        .foregroundStyle(FGColor.dangerRed)
                        .font(FGTypography.caption)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var eventHeader: some View {
        HStack(spacing: FGSpacing.md) {
            FanTeamMarkView(
                sport: context.sportToken,
                logoURL: context.teamLogoURL,
                logoThumbnailURL: context.teamLogoThumbnailURL,
                colorHex: context.teamColorHex,
                size: 44
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(context.teamName)
                    .font(FGTypography.body.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text(context.eventTitle)
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                if let starts = context.eventStartsAt {
                    Text(Self.formatEventWhen(starts, languageCode: languageCode))
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var bottomBar: some View {
        HStack(spacing: FGSpacing.sm) {
            Button {
                Task { await save(status: .draft) }
            } label: {
                Text(L10n.t("fan_team_lineup_save_draft", languageCode: languageCode))
                    .font(FGTypography.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isSaving)

            Button {
                Task { await save(status: .published) }
            } label: {
                Text(L10n.t("fan_team_lineup_publish", languageCode: languageCode))
                    .font(FGTypography.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .disabled(isSaving || members.isEmpty)
        }
        .padding(.horizontal, FGSpacing.lg)
        .padding(.vertical, FGSpacing.md)
        .background(.ultraThinMaterial)
    }

    // MARK: - Mutations

    /// Playing Today ON → `.starting`; OFF → `.bench` (existing lineup_status storage).
    private func applyPlayerEdit(participantKey: UUID, playingToday: Bool, positionCode: String?) {
        guard let idx = members.firstIndex(where: { $0.participantKey == participantKey }) else { return }
        var row = members[idx]
        let status: FanTeamLineupPlayerStatus = playingToday ? .starting : .bench
        row.lineupStatus = status
        row.positionCode = positionCode
        let maxSort = members
            .filter { $0.lineupStatus == status && $0.participantKey != participantKey }
            .map(\.sortOrder)
            .max() ?? -1
        row.sortOrder = maxSort + 1
        members[idx] = row
    }

    /// Ensure every active roster seat appears once (missing → Not Playing / bench).
    /// Guardian-managed seats are seeded on their `managedPlayerId`, never on a
    /// guardian's account id.
    private func seedAllRosterMembers(into drafts: [FanTeamLineupMemberDraft]) -> [FanTeamLineupMemberDraft] {
        var next = FanTeamLineupOrdering.deduped(drafts)
        var seen = Set(next.map(\.participantKey))
        var sort = (next.filter { $0.lineupStatus == .bench }.map(\.sortOrder).max() ?? -1) + 1
        for member in teamMembers where member.isPlayer {
            guard let key = member.participantKey, seen.insert(key).inserted else {
                continue
            }
            let prefill = FanTeamMemberPositionPresentation.lineupPrefillPositionCode(
                preferredPositionCode: member.preferredPositionCode,
                sportToken: sportToken
            )
            next.append(
                FanTeamLineupMemberDraft(
                    userId: member.userId,
                    managedPlayerId: member.managedPlayerId,
                    lineupStatus: .bench,
                    positionCode: prefill,
                    sortOrder: sort
                )
            )
            sort += 1
        }
        return FanTeamLineupOrdering.deduped(next)
    }

    private func bootstrap() async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            async let lineupTask = FanTeamEventLineupService().getLineup(
                pickupGameId: context.pickupGameId,
                teamId: context.teamId
            )
            async let membersTask = FanTeamsService().listMembers(teamId: context.teamId)
            await viewModel.loadPickupGameRoster(pickupGameId: context.pickupGameId, force: false)
            let (lineup, rosterMembers) = try await (lineupTask, membersTask)
            teamMembers = rosterMembers
            viewerCanManage = lineup.viewerCanManage
            // Keep any existing formation for save compatibility; do not expose in UI.
            formation = lineup.formation ?? ""
            members = seedAllRosterMembers(into: lineup.members)
            if !viewerCanManage {
                errorText = L10n.t("fan_team_lineup_edit_forbidden", languageCode: languageCode)
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func save(status: FanTeamLineupPublicationStatus) async {
        guard viewerCanManage, !context.isEventCancelled else { return }
        isSaving = true
        errorText = nil
        defer { isSaving = false }
        do {
            // Formation is not editable in the manager UI; pass through stored value.
            let formationValue = formation.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await FanTeamEventLineupService().saveLineup(
                pickupGameId: context.pickupGameId,
                teamId: context.teamId,
                status: status,
                formation: formationValue.isEmpty ? nil : formationValue,
                members: members
            )
            // Persist members first, then publish so Team Chat gets the
            // idempotent "Lineup published" notice (20260964) without
            // reconstructing seats client-side.
            if status == .published {
                _ = try await FanTeamEventLineupService().publishLineup(
                    pickupGameId: context.pickupGameId,
                    teamId: context.teamId
                )
                dismiss()
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private static func formatEventWhen(_ date: Date, languageCode: String) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: languageCode)
        df.dateStyle = .medium
        df.timeStyle = .short
        return df.string(from: date)
    }
}

// MARK: - Published view

struct FanTeamEventLineupPublishedView: View {
    let context: FanTeamEventLineupContext
    @ObservedObject var viewModel: MapViewModel
    var onRequestEdit: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @State private var lineup: FanTeamEventLineup?
    @State private var teamMembers: [FanTeamMember] = []
    @State private var isLoading = true
    @State private var errorText: String?

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var accent: Color { FanTeamLineupAppearance.accent }

    /// Keyed by roster-seat participant key: the account id, or the managed player
    /// id for a guardian-managed seat (20260961).
    private var teamById: [UUID: FanTeamMember] {
        Dictionary(
            uniqueKeysWithValues: teamMembers.compactMap { member in
                member.participantKey.map { ($0, member) }
            }
        )
    }

    private var attendanceById: [UUID: PickupDetailAttendanceCategory] {
        guard let roster = viewModel.pickupGameRosterByGameId[context.pickupGameId] else { return [:] }
        var map: [UUID: PickupDetailAttendanceCategory] = [:]
        for row in PickupTeamAttendancePresentation.rows(from: roster) {
            map[row.id] = row.category
        }
        return map
    }

    private var rosterById: [UUID: PickupGameRosterMember] {
        guard let roster = viewModel.pickupGameRosterByGameId[context.pickupGameId] else { return [:] }
        var map: [UUID: PickupGameRosterMember] = [:]
        for row in PickupTeamAttendancePresentation.rows(from: roster) {
            map[row.id] = row.member
        }
        return map
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorText {
                    FanTeamEventLineupPublishedEmptyStateView(
                        languageCode: languageCode,
                        accent: accent
                    )
                    .overlay(alignment: .bottom) {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                } else if let lineup, lineup.isPublished {
                    publishedPlayerParentList(lineup)
                } else {
                    FanTeamEventLineupPublishedEmptyStateView(
                        languageCode: languageCode,
                        accent: accent
                    )
                }
            }
            .fanGeoScreenBackground()
            .navigationTitle(L10n.t("fan_team_lineup_title", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Done", languageCode: languageCode)) { dismiss() }
                }
                if lineup?.viewerCanManage == true,
                   !context.isEventCancelled,
                   onRequestEdit != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button(L10n.t("Edit", languageCode: languageCode)) {
                            onRequestEdit?()
                        }
                        .foregroundStyle(accent)
                        .accessibilityLabel(L10n.t("fan_team_lineup_edit", languageCode: languageCode))
                    }
                }
            }
            .task {
                await load()
            }
            .onChange(of: viewModel.pickupOrganizerRequestsSyncGeneration) { _, _ in
                Task { await load() }
            }
        }
    }

    /// Player/parent published lineup: position-first flat list (no formation, no Starting/Bench headers).
    private func publishedPlayerParentList(_ lineup: FanTeamEventLineup) -> some View {
        let players = FanTeamLineupPresentation.playerParentOrderedPlayers(
            from: lineup,
            sportToken: context.sportToken,
            teamMembersById: teamById,
            attendanceById: attendanceById,
            rosterMembersById: rosterById,
            currentUserId: viewModel.currentUserAuthId
        )

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                FanTeamEventLineupPublishedHeaderView(
                    languageCode: languageCode,
                    accent: accent
                )
                .padding(.bottom, 4)

                if players.isEmpty {
                    FanTeamEventLineupPublishedEmptyStateView(
                        languageCode: languageCode,
                        accent: accent
                    )
                    .frame(minHeight: 220)
                } else {
                    ForEach(players) { row in
                        FanTeamEventLineupPlayerParentRowView(
                            player: row,
                            sportToken: context.sportToken,
                            languageCode: languageCode,
                            accent: accent
                        )
                    }
                }

                FanTeamEventLineupPublishedFooterNote(
                    languageCode: languageCode,
                    accent: accent
                )
                .padding(.top, 8)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
    }

    private func load() async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            async let lineupTask = FanTeamEventLineupService().getLineup(
                pickupGameId: context.pickupGameId,
                teamId: context.teamId
            )
            async let membersTask = FanTeamsService().listMembers(teamId: context.teamId)
            await viewModel.loadPickupGameRoster(pickupGameId: context.pickupGameId, force: false)
            let (loaded, rosterMembers) = try await (lineupTask, membersTask)
            lineup = loaded
            teamMembers = rosterMembers
            if !loaded.isPublished {
                errorText = L10n.t("fan_team_lineup_not_published_yet", languageCode: languageCode)
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Shared row

private struct FanTeamEventLineupPlayerRowView: View {
    let player: FanTeamLineupPlayerPresentation
    let sportToken: String
    let languageCode: String
    let accent: Color
    let showsDragHint: Bool
    var supportsPositions: Bool = false
    var isPositionEditable: Bool = false
    var onPositionTap: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    private var avatarFallback: UserAvatarView.FallbackStyle {
        colorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome
    }

    private var resolvedPosition: FanTeamSportPositions.Position? {
        FanTeamSportPositions.position(code: player.positionCode, sportToken: sportToken)
    }

    var body: some View {
        HStack(spacing: FGSpacing.sm) {
            UserAvatarView(
                avatarThumbnailURL: player.avatarThumbnailURL,
                avatarURL: player.avatarURL ?? "",
                avatarDisplayRefreshToken: .init(),
                displayName: player.displayName,
                email: "",
                size: 40,
                fallbackStyle: avatarFallback
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let number = player.numberLabel {
                        Text(number)
                            .font(FGTypography.caption.weight(.bold))
                            .foregroundStyle(accent)
                    }
                    Text(player.displayName)
                        .font(FGTypography.body.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                if player.isCurrentUser {
                    Text(L10n.t("pickup_attendance_you", languageCode: languageCode))
                        .font(FGTypography.caption.weight(.bold))
                        .foregroundStyle(accent)
                }
                if FanTeamLineupEligibility.showsSecondaryRSVPChip(attendance: player.attendance),
                   let attendance = player.attendance {
                    Text(L10n.t(attendance.aggregateTitleKey(), languageCode: languageCode))
                        .font(FGTypography.caption)
                        .foregroundStyle(
                            FanTeamLineupEligibility.showsNoLongerAttendingWarning(attendance: attendance)
                                ? FGColor.dangerRed
                                : FGColor.secondaryText(colorScheme)
                        )
                }
            }

            Spacer(minLength: 8)

            if supportsPositions || isPositionEditable {
                positionControl
            }

            if showsDragHint {
                Image(systemName: "line.3.horizontal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            FanTeamLineupPresentation.accessibilityRowLabel(
                player: player,
                sportToken: sportToken,
                languageCode: languageCode
            )
        )
    }

    private var displayPositionLabel: String? {
        FanTeamLineupPresentation.displayPositionCode(
            positionCode: player.positionCode,
            sportToken: sportToken
        )
    }

    @ViewBuilder
    private var positionControl: some View {
        if isPositionEditable, let onPositionTap {
            let label = displayPositionLabel
                ?? L10n.t("fan_team_lineup_set_position", languageCode: languageCode)
            Button(action: onPositionTap) {
                positionPill(text: label, emphasized: displayPositionLabel != nil)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(positionControlAccessibilityLabel)
        } else if let label = displayPositionLabel {
            // Read-only: compact trailing code — never hide a stored position_code.
            Text(label)
                .font(FGTypography.caption.weight(.bold))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityHidden(true)
        }
    }

    private func positionPill(text: String, emphasized: Bool) -> some View {
        Text(text)
            .font(FGTypography.caption.weight(.bold))
            .foregroundStyle(emphasized ? accent : FGColor.secondaryText(colorScheme))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(
                    emphasized
                        ? accent.opacity(colorScheme == .dark ? 0.22 : 0.12)
                        : FGColor.secondaryText(colorScheme).opacity(colorScheme == .dark ? 0.18 : 0.10)
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    emphasized
                        ? accent.opacity(0.35)
                        : FGColor.divider(colorScheme).opacity(0.55),
                    lineWidth: 1
                )
            )
    }

    private var positionControlAccessibilityLabel: String {
        if let resolvedPosition {
            return String(
                format: L10n.t(
                    "fan_team_lineup_position_control_change_a11y_format",
                    languageCode: languageCode
                ),
                locale: Locale(identifier: languageCode),
                resolvedPosition.accessibilityLabel(languageCode: languageCode)
            )
        }
        if let code = displayPositionLabel {
            return String(
                format: L10n.t(
                    "fan_team_lineup_position_control_change_a11y_format",
                    languageCode: languageCode
                ),
                locale: Locale(identifier: languageCode),
                code
            )
        }
        return L10n.t("fan_team_lineup_position_control_set_a11y", languageCode: languageCode)
    }
}
