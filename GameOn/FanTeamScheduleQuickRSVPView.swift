import SwiftUI

/// Compact Team Schedule RSVP strip — leaf control (sibling of card open, never nested Button).
struct FanTeamScheduleQuickRSVPView: View {
    let gameId: UUID
    let subject: FanTeamRSVPSubject
    let accent: Color
    let languageCode: String
    /// When true, show read-only “Not participating” (event-removal hook).
    var isExcluded: Bool = false
    @ObservedObject var mapViewModel: MapViewModel

    @Environment(\.colorScheme) private var colorScheme

    @State private var optimisticState: FanTeamScheduleQuickRSVPState?
    @State private var isSaving = false
    @State private var showChangeMenu = false
    @State private var saveError: String?
    /// Monotonic token so a stale async completion for this `gameId` cannot clobber a newer tap.
    @State private var applyGeneration = 0

    private var roster: PickupGameRosterPayload? {
        mapViewModel.pickupGameRosterByGameId[gameId]
    }

    private var explicitSelfRSVP: FanTeamCachedSelfRSVP? {
        // Managed seats are not stored in get_fan_team_game_rsvp (account RPC).
        guard !subject.isManagedPlayer else { return nil }
        return mapViewModel.fanTeamSelfRSVPByGameId[gameId]
    }

    private var resolvedState: FanTeamScheduleQuickRSVPState {
        if let optimisticState { return optimisticState }
        return FanTeamScheduleQuickRSVPState.resolve(
            subjectUserId: subject.rosterAttendanceUserId,
            roster: roster,
            explicitSelfRSVP: explicitSelfRSVP,
            fallbackRSVP: nil
        )
    }

    private var subjectName: String { subject.promptDisplayName }

    var body: some View {
        Group {
            if isExcluded {
                excludedRow
            } else {
                interactiveRow
            }
        }
        .confirmationDialog(
            FanTeamScheduleQuickRSVPCopy.prompt(
                subjectName: subjectName,
                languageCode: languageCode
            ),
            isPresented: $showChangeMenu,
            titleVisibility: .visible
        ) {
            ForEach(FanTeamGameRSVPStatus.allCases, id: \.self) { status in
                Button(FanTeamScheduleQuickRSVPCopy.menuTitle(for: status, languageCode: languageCode)) {
                    Task { await apply(status) }
                }
            }
            Button(L10n.t("Cancel", languageCode: languageCode), role: .cancel) {}
        }
        .alert(
            L10n.t("fan_team_schedule_rsvp_save_failed", languageCode: languageCode),
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )
        ) {
            Button(L10n.t("OK", languageCode: languageCode), role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .onChange(of: mapViewModel.pickupOrganizerRequestsSyncGeneration) { _, _ in
            clearOptimisticIfServerMatches()
        }
        .onChange(of: mapViewModel.fanTeamSelfRSVPByGameId[gameId]) { _, _ in
            clearOptimisticIfServerMatches()
        }
    }

    private func clearOptimisticIfServerMatches() {
        guard let optimistic = optimisticState else { return }
        let server = FanTeamScheduleQuickRSVPState.resolve(
            subjectUserId: subject.rosterAttendanceUserId,
            roster: roster,
            explicitSelfRSVP: explicitSelfRSVP,
            fallbackRSVP: nil
        )
        if server == optimistic {
            optimisticState = nil
        }
    }

    private var excludedRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.slash")
                .font(.caption.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .accessibilityHidden(true)
            Text(L10n.t("fan_team_schedule_rsvp_not_participating", languageCode: languageCode))
                .font(.caption.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            L10n.t("fan_team_schedule_rsvp_not_participating", languageCode: languageCode)
        )
    }

    @ViewBuilder
    private var interactiveRow: some View {
        switch resolvedState {
        case .noResponse:
            noResponseRow
        case .going, .maybe, .cantGo:
            confirmedRow(resolvedState)
        }
    }

    private var noResponseRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                promptText(
                    FanTeamScheduleQuickRSVPCopy.prompt(
                        subjectName: subjectName,
                        languageCode: languageCode
                    )
                )
                Spacer(minLength: 8)
                quickActionPair
            }
            VStack(alignment: .leading, spacing: 8) {
                promptText(
                    FanTeamScheduleQuickRSVPCopy.prompt(
                        subjectName: subjectName,
                        languageCode: languageCode
                    )
                )
                HStack {
                    Spacer(minLength: 0)
                    quickActionPair
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func confirmedRow(_ state: FanTeamScheduleQuickRSVPState) -> some View {
        let title = FanTeamScheduleQuickRSVPCopy.confirmed(
            state: state,
            subjectName: subjectName,
            languageCode: languageCode
        )
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                statusGlyph(state)
                promptText(title)
                    .foregroundStyle(statusForeground(state))
                Spacer(minLength: 8)
                changeButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    statusGlyph(state)
                    promptText(title)
                        .foregroundStyle(statusForeground(state))
                }
                HStack {
                    Spacer(minLength: 0)
                    changeButton
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var quickActionPair: some View {
        HStack(spacing: 8) {
            quickActionButton(
                systemImage: "xmark",
                tint: FGColor.dangerRed,
                accessibilityLabel: FanTeamScheduleQuickRSVPCopy.markCantGoA11y(
                    subjectName: subjectName,
                    languageCode: languageCode
                )
            ) {
                Task { await apply(.cant_go) }
            }
            quickActionButton(
                systemImage: "checkmark",
                tint: accent,
                accessibilityLabel: FanTeamScheduleQuickRSVPCopy.markGoingA11y(
                    subjectName: subjectName,
                    languageCode: languageCode
                )
            ) {
                Task { await apply(.going) }
            }
        }
    }

    private func quickActionButton(
        systemImage: String,
        tint: Color,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(
                    Circle().fill(tint.opacity(colorScheme == .dark ? 0.22 : 0.12))
                )
                .overlay {
                    Circle().strokeBorder(tint.opacity(0.35), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
        .accessibilityLabel(accessibilityLabel)
    }

    private var changeButton: some View {
        Button {
            showChangeMenu = true
        } label: {
            Text(L10n.t("fan_team_schedule_rsvp_change", languageCode: languageCode))
                .font(.caption.weight(.bold))
                .foregroundStyle(accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(accent.opacity(colorScheme == .dark ? 0.22 : 0.12))
                )
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
        .accessibilityLabel(
            FanTeamScheduleQuickRSVPCopy.changeA11y(
                subjectName: subjectName,
                languageCode: languageCode
            )
        )
    }

    private func promptText(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(FGColor.primaryText(colorScheme))
            .lineLimit(2)
            .minimumScaleFactor(0.85)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func statusGlyph(_ state: FanTeamScheduleQuickRSVPState) -> some View {
        Image(systemName: {
            switch state {
            case .going: return "checkmark.circle.fill"
            case .maybe: return "questionmark.circle.fill"
            case .cantGo: return "xmark.circle.fill"
            case .noResponse: return "circle"
            }
        }())
        .font(.caption.weight(.bold))
        .foregroundStyle(statusForeground(state))
        .accessibilityHidden(true)
    }

    private func statusForeground(_ state: FanTeamScheduleQuickRSVPState) -> Color {
        switch state {
        case .going: return accent
        case .maybe: return FGColor.secondaryText(colorScheme)
        case .cantGo: return FGColor.dangerRed
        case .noResponse: return FGColor.primaryText(colorScheme)
        }
    }

    @MainActor
    private func apply(_ status: FanTeamGameRSVPStatus) async {
        // Writes go through the roster-seat RPC, which authorizes the caller as
        // either the seat owner or an active guardian. The only case the client
        // can rule out locally is "someone else's account".
        if let subjectUserId = subject.userId,
           subjectUserId != mapViewModel.currentUserAuthId {
            saveError = L10n.t("fan_team_schedule_rsvp_save_failed", languageCode: languageCode)
            return
        }

        applyGeneration += 1
        let generation = applyGeneration
        let previous = resolvedState
        let next = FanTeamScheduleQuickRSVPState.from(rsvp: status)
        optimisticState = next
        isSaving = true
        defer {
            if generation == applyGeneration {
                isSaving = false
            }
        }

        do {
#if DEBUG
            print(
                "[TeamRSVPDebug] schedule_quick_rsvp pickup_game_id=\(gameId.uuidString.lowercased()) " +
                "subject=\(subject.id.uuidString.lowercased()) " +
                "managed=\(subject.isManagedPlayer) requested=\(status.rawValue) " +
                "previous=\(String(describing: previous)) generation=\(generation)"
            )
#endif
            if let membershipId = subject.membershipId {
                try await FanTeamsService().setRSVP(
                    gameId: gameId,
                    membershipId: membershipId,
                    status: status,
                    isManagedPlayer: subject.isManagedPlayer
                )
            } else {
                try await FanTeamsService().setRSVP(gameId: gameId, status: status)
            }

            // Ignore stale completions after a newer tap on this same card.
            guard generation == applyGeneration else { return }

            // Authoritative write-through for THIS event only.
            if !subject.isManagedPlayer {
                mapViewModel.fanTeamSelfRSVPByGameId[gameId] = .status(status)
            }
            await mapViewModel.loadTeamScheduleAttendance(pickupGameId: gameId, force: true)
            await mapViewModel.syncPickupGamesToAppleCalendarIfNeeded(
                reason: "teamScheduleQuickRSVP",
                forceBypassFreshness: true
            )

            guard generation == applyGeneration else { return }

            let server = FanTeamScheduleQuickRSVPState.resolve(
                subjectUserId: subject.rosterAttendanceUserId,
                roster: mapViewModel.pickupGameRosterByGameId[gameId],
                explicitSelfRSVP: subject.isManagedPlayer
                    ? nil
                    : mapViewModel.fanTeamSelfRSVPByGameId[gameId],
                fallbackRSVP: nil
            )
            optimisticState = (server == next) ? nil : next
            saveError = nil
        } catch {
#if DEBUG
            print(
                "[TeamRSVPDebug] schedule_quick_rsvp_failed pickup_game_id=\(gameId.uuidString.lowercased()) " +
                "requested=\(status.rawValue) raw=\(error.localizedDescription)"
            )
#endif
            guard generation == applyGeneration else { return }
            // Rollback optimistic UI to prior resolved state (not stuck on failed target).
            optimisticState = (previous == .noResponse) ? nil : previous
            saveError = FanTeamRSVPErrorMapping.userFacingMessage(
                for: error,
                languageCode: languageCode
            )
        }
    }
}
