import SwiftUI

/// Optional staff context for Team-linked Who's Going (event exclusion management).
struct FanTeamAttendanceStaffContext: Equatable {
    let teamId: UUID
    let teamName: String
    let canManageEventRoster: Bool
}

/// Team-linked Pickup attendance roster for **this game** (membership + RSVP).
/// Concrete leaf view — keep out of DiscoverScreen / giant detail `@ViewBuilder` chains.
struct PickupTeamAttendanceRosterSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let pickupGameId: UUID
    var staffContext: FanTeamAttendanceStaffContext? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @State private var memberPendingEventRemoval: PickupGameRosterMember?
    @State private var isMutatingExclusion = false
    @State private var exclusionError: String?

    private let teamsService = FanTeamsService()

    private var languageCode: String {
        L10n.normalizedLanguageCode(appLanguageRaw)
    }

    private var roster: PickupGameRosterPayload? {
        viewModel.pickupGameRosterByGameId[pickupGameId]
    }

    private var canManageEventRoster: Bool {
        if let staffContext { return staffContext.canManageEventRoster }
        return roster?.canManageEventRoster == true
    }

    private var resolvedTeamId: UUID? { staffContext?.teamId }

    private var avatarFallback: UserAvatarView.FallbackStyle {
        colorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome
    }

    var body: some View {
        NavigationStack {
            Group {
                if let roster {
                    attendanceList(roster)
                } else if viewModel.pickupGameRosterInFlightGameIds.contains(pickupGameId) {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = viewModel.pickupGameRosterErrorByGameId[pickupGameId], !err.isEmpty {
                    ContentUnavailableView(
                        L10n.t("pickup_detail_whos_going", languageCode: languageCode),
                        systemImage: "person.3",
                        description: Text(err)
                    )
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .task {
                            await viewModel.loadPickupGameRoster(pickupGameId: pickupGameId, force: true)
                        }
                }
            }
            .fanGeoScreenBackground()
            .navigationTitle(L10n.t("pickup_detail_whos_going", languageCode: languageCode))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("Done", languageCode: languageCode)) { dismiss() }
                }
            }
            .task(id: pickupGameId) {
                await viewModel.loadPickupGameRoster(pickupGameId: pickupGameId, force: true)
            }
            .onChange(of: viewModel.pickupOrganizerRequestsSyncGeneration) { _, _ in
                Task { await viewModel.refreshPickupGameRoster(pickupGameId: pickupGameId) }
            }
            .alert(
                L10n.t("fan_teams_remove_from_event_confirm_title", languageCode: languageCode),
                isPresented: Binding(
                    get: { memberPendingEventRemoval != nil },
                    set: { if !$0 { memberPendingEventRemoval = nil } }
                )
            ) {
                Button(L10n.t("Cancel", languageCode: languageCode), role: .cancel) {
                    memberPendingEventRemoval = nil
                }
                Button(
                    L10n.t("fan_teams_remove_from_event_confirm_action", languageCode: languageCode),
                    role: .destructive
                ) {
                    if let member = memberPendingEventRemoval {
                        Task { await setExcluded(member, excluded: true) }
                    }
                }
            } message: {
                Text(
                    String(
                        format: L10n.t(
                            "fan_teams_remove_from_event_confirm_body_format",
                            languageCode: languageCode
                        ),
                        locale: Locale(identifier: languageCode),
                        memberPendingEventRemoval?.resolvedDisplayName ?? "",
                        staffContext?.teamName ?? L10n.t("fan_teams_your_teams", languageCode: languageCode)
                    )
                )
            }
            .alert(
                L10n.t("fan_teams_error_title", languageCode: languageCode),
                isPresented: Binding(
                    get: { exclusionError != nil },
                    set: { if !$0 { exclusionError = nil } }
                )
            ) {
                Button(L10n.t("OK", languageCode: languageCode), role: .cancel) {}
            } message: {
                Text(exclusionError ?? "")
            }
        }
    }

    @ViewBuilder
    private func attendanceList(_ roster: PickupGameRosterPayload) -> some View {
        let attendanceRows = PickupTeamAttendancePresentation.rows(from: roster)
        let counts = PickupTeamAttendancePresentation.counts(from: roster)
        let excluded = roster.excludedMembers

        List {
            Section {
                Text(summaryLine(counts: counts))
                    .font(FGTypography.metadata.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .listRowBackground(Color.clear)
                    .accessibilityLabel(summaryAccessibilityLabel(counts: counts))
            }

            Section {
                if attendanceRows.isEmpty {
                    Text(L10n.t("pickup_detail_nobody_in_group", languageCode: languageCode))
                        .font(FGTypography.body)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(attendanceRows) { row in
                        attendanceRow(row, isExcluded: false)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
            }

            if canManageEventRoster, !excluded.isEmpty {
                Section {
                    ForEach(excluded, id: \.user_id) { member in
                        attendanceRow(
                            PickupTeamAttendanceRow(member: member, category: .noResponse),
                            isExcluded: true
                        )
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    Text(L10n.t("fan_teams_excluded_from_event_section", languageCode: languageCode))
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
    }

    private func attendanceRow(_ row: PickupTeamAttendanceRow, isExcluded: Bool) -> some View {
        let member = row.member
        let handle = FanTeamRosterRowPresentation.parentheticalHandle(username: member.username)
        // A managed player has no account: its `user_id` is a managed_player_id, so
        // it can never be the viewer and must never route to a public profile.
        let isYou = !member.isManagedPlayer && member.user_id == viewModel.currentUserAuthId
        let supportsProfile = !member.isManagedPlayer
        let statusTitle = isExcluded
            ? L10n.t("fan_teams_excluded_from_event_status", languageCode: languageCode)
            : L10n.t(row.category.aggregateTitleKey(), languageCode: languageCode)
        let identity = FanTeamRosterRowPresentation.identityLine(
            displayName: member.resolvedDisplayName,
            username: member.username
        )
        let showStaffMenu = canManageEventRoster
            && resolvedTeamId != nil
            && !isYou

        return HStack(spacing: 12) {
            Button {
                guard supportsProfile else { return }
                viewModel.presentPublicProfile(
                    userId: member.user_id,
                    context: "pickup_team_attendance",
                    isSelfPreview: isYou
                )
            } label: {
                HStack(spacing: 12) {
                    UserAvatarView(
                        avatarThumbnailURL: member.avatar_thumbnail_url,
                        avatarURL: member.avatar_url ?? "",
                        avatarDisplayRefreshToken: .init(),
                        displayName: member.resolvedDisplayName,
                        email: "",
                        size: 40,
                        fallbackStyle: avatarFallback,
                        imagePlaceholderTint: colorScheme == .dark ? .white.opacity(0.75) : nil
                    )
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(member.resolvedDisplayName)
                                .font(FGTypography.metadata.weight(.semibold))
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                                .lineLimit(1)
                            if let handle {
                                Text("(\(handle))")
                                    .font(FGTypography.caption.weight(.medium))
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                                    .lineLimit(1)
                            }
                            if isYou {
                                Text(L10n.t("pickup_attendance_you", languageCode: languageCode))
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(FGColor.accentGreen)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        FGColor.accentGreen.opacity(colorScheme == .dark ? 0.22 : 0.12),
                                        in: Capsule(style: .continuous)
                                    )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(statusTitle)
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(
                            isExcluded
                                ? FGColor.dangerRed.opacity(colorScheme == .dark ? 0.85 : 0.78)
                                : statusForeground(row.category)
                        )
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            (isExcluded
                                ? FGColor.dangerRed
                                : statusForeground(row.category)
                            ).opacity(colorScheme == .dark ? 0.20 : 0.12),
                            in: Capsule(style: .continuous)
                        )
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!supportsProfile)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                isYou
                    ? "\(identity), \(L10n.t("pickup_attendance_you", languageCode: languageCode)), \(statusTitle)"
                    : "\(identity), \(statusTitle)"
            )

            if showStaffMenu {
                Menu {
                    if supportsProfile {
                        Button {
                            viewModel.presentPublicProfile(
                                userId: member.user_id,
                                context: "pickup_team_attendance_menu",
                                isSelfPreview: false
                            )
                        } label: {
                            Label(
                                L10n.t("View Profile", languageCode: languageCode),
                                systemImage: "person.crop.circle"
                            )
                        }

                        Divider()
                    }

                    if isExcluded {
                        Button {
                            Task { await setExcluded(member, excluded: false) }
                        } label: {
                            Label(
                                L10n.t("fan_teams_add_back_to_event", languageCode: languageCode),
                                systemImage: "person.badge.plus"
                            )
                        }
                        .disabled(isMutatingExclusion)
                    } else {
                        Button(role: .destructive) {
                            memberPendingEventRemoval = member
                        } label: {
                            Label(
                                L10n.t("fan_teams_remove_from_event", languageCode: languageCode),
                                systemImage: "person.fill.xmark"
                            )
                        }
                        .disabled(isMutatingExclusion)
                        .accessibilityLabel(
                            L10n.t("fan_teams_remove_from_event", languageCode: languageCode)
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(L10n.t("More", languageCode: languageCode))
            }
        }
        .padding(.vertical, 2)
    }

    @MainActor
    private func setExcluded(_ member: PickupGameRosterMember, excluded: Bool) async {
        guard let teamId = resolvedTeamId, !isMutatingExclusion else { return }
        isMutatingExclusion = true
        defer {
            isMutatingExclusion = false
            memberPendingEventRemoval = nil
        }
        do {
            // Managed seats are addressable only by membership_id (they have no user_id).
            if let membershipId = member.membership_id, member.isManagedPlayer {
                try await teamsService.setEventMembershipExcluded(
                    teamId: teamId,
                    pickupGameId: pickupGameId,
                    membershipId: membershipId,
                    excluded: excluded
                )
            } else {
                try await teamsService.setEventMemberExcluded(
                    teamId: teamId,
                    pickupGameId: pickupGameId,
                    userId: member.user_id,
                    excluded: excluded
                )
            }
            await viewModel.refreshPickupGameRoster(pickupGameId: pickupGameId)
        } catch {
            if FanTeamsLoadErrorPresentation.isCancellation(error) { return }
            exclusionError = L10n.t(
                excluded
                    ? "fan_teams_remove_from_event_failed"
                    : "fan_teams_add_back_to_event_failed",
                languageCode: languageCode
            )
        }
    }

    private func statusForeground(_ category: PickupDetailAttendanceCategory) -> Color {
        switch category {
        case .going:
            return FGColor.accentGreen
        case .maybe:
            return FGColor.intentPlay
        case .noResponse:
            return FGColor.secondaryText(colorScheme)
        case .cantGo:
            return FGColor.dangerRed.opacity(colorScheme == .dark ? 0.85 : 0.78)
        }
    }

    private func summaryLine(counts: (going: Int, maybe: Int, noResponse: Int, cantGo: Int)) -> String {
        var parts = [
            "\(counts.going) \(L10n.t("Going", languageCode: languageCode))",
            "\(counts.maybe) \(L10n.t("Maybe", languageCode: languageCode))",
            "\(counts.noResponse) \(L10n.t("pickup_detail_no_response", languageCode: languageCode))"
        ]
        if counts.cantGo > 0 {
            parts.append(
                "\(counts.cantGo) \(L10n.t("fan_team_rsvp_cant_go", languageCode: languageCode))"
            )
        }
        return parts.joined(separator: " · ")
    }

    private func summaryAccessibilityLabel(
        counts: (going: Int, maybe: Int, noResponse: Int, cantGo: Int)
    ) -> String {
        var parts: [String] = []
        if counts.going > 0 {
            parts.append("\(counts.going) \(L10n.t("Going", languageCode: languageCode))")
        }
        if counts.maybe > 0 {
            parts.append("\(counts.maybe) \(L10n.t("Maybe", languageCode: languageCode))")
        }
        if counts.noResponse > 0 {
            parts.append(
                "\(counts.noResponse) \(L10n.t("pickup_detail_no_response", languageCode: languageCode))"
            )
        }
        if counts.cantGo > 0 {
            parts.append(
                "\(counts.cantGo) \(L10n.t("fan_team_rsvp_cant_go", languageCode: languageCode))"
            )
        }
        if parts.isEmpty {
            return L10n.t("pickup_detail_whos_going", languageCode: languageCode)
        }
        return "\(L10n.t("pickup_detail_whos_going", languageCode: languageCode)). \(parts.joined(separator: ", "))"
    }
}
