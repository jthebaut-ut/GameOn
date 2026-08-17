import SwiftUI

/// Compact Team Live/Final scoreboard. Owner/Manager get +/- ; members are read-only.
struct FanTeamEventScoreboardView: View {
    let teamName: String
    let opponentName: String
    let teamScore: Int
    let opponentScore: Int
    let status: FanTeamEventScoringStatus
    let canEdit: Bool
    let languageCode: String
    let accent: Color
    let isBusy: Bool
    let errorText: String?
    var sport: String = ""
    var scoringTeamId: UUID? = nil
    var opponentTeamId: UUID? = nil
    let onTeamDelta: (Int, UUID?) -> Void
    let onOpponentDelta: (Int, UUID?) -> Void
    let onMarkLive: () -> Void
    let onMarkFinal: () -> Void
    let onCorrectResult: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @State private var pendingPlusSide: PendingPlusSide?
    @State private var didConfirmScorer = false

    private enum PendingPlusSide: Identifiable {
        case team
        case opponent
        var id: String {
            switch self {
            case .team: return "team"
            case .opponent: return "opponent"
            }
        }
    }

    var body: some View {
        TeamEventPlayerCardChrome(tint: accent.opacity(0.55)) {
            VStack(alignment: .leading, spacing: 12) {
                statusBadge

                scoreRow(
                    name: teamName,
                    score: teamScore,
                    onDelta: canEditLive ? { handleDelta(side: .team, delta: $0) } : nil
                )
                scoreRow(
                    name: opponentName,
                    score: opponentScore,
                    onDelta: canEditLive ? { handleDelta(side: .opponent, delta: $0) } : nil
                )

                if let errorText, !errorText.isEmpty {
                    Text(errorText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FGColor.dangerRed)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if canEdit {
                    actionButtons
                }
            }
        }
        .accessibilityElement(children: .contain)
        .sheet(item: $pendingPlusSide, onDismiss: {
            if !didConfirmScorer {
                pendingPlusSide = nil
            }
            didConfirmScorer = false
        }) { side in
            FanTeamScorerPickerSheet(
                mode: attributionMode,
                scorers: scorers(for: side),
                languageCode: languageCode,
                accent: accent,
                onPick: { pick in
                    didConfirmScorer = true
                    applyPlus(side: side, scorerMembershipId: pick.membershipId)
                    pendingPlusSide = nil
                },
                onCancel: {
                    didConfirmScorer = true
                    pendingPlusSide = nil
                }
            )
        }
        .task(id: scoringTeamId) {
            guard let scoringTeamId, canEdit else { return }
            guard !FanTeamRosterSnapshotCache.hasSnapshot(for: scoringTeamId) else { return }
            if let members = try? await FanTeamsService().listMembers(teamId: scoringTeamId) {
                FanTeamRosterSnapshotCache.store(members, for: scoringTeamId)
            }
        }
    }

    private var canEditLive: Bool {
        canEdit && status == .live && !isBusy
    }

    private var attributionMode: FanTeamScorerAttributionMode {
        FanTeamScoreAttribution.mode(forSport: sport)
    }

    private func scorers(for side: PendingPlusSide) -> [FanTeamEligibleScorer] {
        switch side {
        case .team:
            guard let scoringTeamId else { return [] }
            return FanTeamRosterSnapshotCache.eligibleScorers(for: scoringTeamId)
        case .opponent:
            guard let opponentTeamId else { return [] }
            return FanTeamRosterSnapshotCache.eligibleScorers(for: opponentTeamId)
        }
    }

    private func handleDelta(side: PendingPlusSide, delta: Int) {
        guard delta > 0, attributionMode.promptsForScorer else {
            applyDelta(side: side, delta: delta, scorerMembershipId: nil)
            return
        }
        switch side {
        case .team:
            didConfirmScorer = false
            pendingPlusSide = .team
        case .opponent:
            if opponentTeamId != nil, !scorers(for: .opponent).isEmpty {
                didConfirmScorer = false
                pendingPlusSide = .opponent
            } else {
                applyDelta(side: .opponent, delta: 1, scorerMembershipId: nil)
            }
        }
    }

    private func applyPlus(side: PendingPlusSide, scorerMembershipId: UUID?) {
        applyDelta(side: side, delta: 1, scorerMembershipId: scorerMembershipId)
    }

    private func applyDelta(side: PendingPlusSide, delta: Int, scorerMembershipId: UUID?) {
        switch side {
        case .team: onTeamDelta(delta, scorerMembershipId)
        case .opponent: onOpponentDelta(delta, scorerMembershipId)
        }
    }

    private var statusBadge: some View {
        Text(statusLabel)
            .font(.caption.weight(.bold))
            .tracking(0.6)
            .foregroundStyle(Color.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(status == .live ? FGColor.dangerRed : accent))
            .accessibilityLabel(statusLabel)
    }

    private var statusLabel: String {
        switch status {
        case .live:
            return L10n.t("fan_team_score_live", languageCode: languageCode)
        case .final:
            return L10n.t("fan_team_score_final", languageCode: languageCode)
        case .scheduled:
            return L10n.t("fan_team_score_scheduled", languageCode: languageCode)
        }
    }

    private func scoreRow(name: String, score: Int, onDelta: ((Int) -> Void)?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(name)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(score)")
                .font(.system(.title, design: .rounded).weight(.bold).monospacedDigit())
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .accessibilityLabel("\(name) \(score)")

            if let onDelta {
                HStack(spacing: 8) {
                    scoreButton(systemName: "minus", enabled: score > 0) { onDelta(-1) }
                    scoreButton(systemName: "plus", enabled: true) { onDelta(1) }
                }
            }
        }
    }

    private func scoreButton(systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.bold))
                .foregroundStyle(enabled ? Color.white : FGColor.secondaryText(colorScheme))
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(enabled ? accent : FGColor.secondaryText(colorScheme).opacity(0.18))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled || isBusy)
        .accessibilityLabel(systemName == "plus" ? "Increase score" : "Decrease score")
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch status {
        case .scheduled:
            Button(action: onMarkLive) {
                labelButton(L10n.t("fan_team_score_mark_live", languageCode: languageCode))
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
        case .live:
            Button(action: onMarkFinal) {
                labelButton(L10n.t("fan_team_score_mark_final", languageCode: languageCode))
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
        case .final:
            if let onCorrectResult {
                Button(action: onCorrectResult) {
                    labelButton(L10n.t("fan_team_score_correct_result", languageCode: languageCode), outlined: true)
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
            }
        }
    }

    private func labelButton(_ title: String, outlined: Bool = false) -> some View {
        Text(title)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(outlined ? accent : Color.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(outlined ? Color.clear : accent)
            )
            .overlay {
                if outlined {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(accent, lineWidth: 1.5)
                }
            }
    }
}

/// Compact FINAL result used on Schedule Past cards and Overview recent results.
struct FanTeamEventResultScoreLine: View {
    let teamName: String
    let opponentName: String
    let teamScore: Int
    let opponentScore: Int
    let languageCode: String
    var showsFinalBadge: Bool = true

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsFinalBadge {
                Text(L10n.t("fan_team_score_final", languageCode: languageCode))
                    .font(.caption2.weight(.bold))
                    .tracking(0.5)
                    .foregroundStyle(FGColor.intentTeams)
            }
            HStack {
                Text(teamName)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(teamScore)")
                    .fontWeight(.bold)
                    .monospacedDigit()
            }
            HStack {
                Text(opponentName)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(opponentScore)")
                    .fontWeight(.bold)
                    .monospacedDigit()
            }
            Text(
                L10n.t(
                    FanTeamEventScoring.result(teamScore: teamScore, opponentScore: opponentScore).badgeKey,
                    languageCode: languageCode
                )
            )
            .font(.caption.weight(.bold))
            .foregroundStyle(FGColor.intentTeams)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(FGColor.primaryText(colorScheme))
    }
}
