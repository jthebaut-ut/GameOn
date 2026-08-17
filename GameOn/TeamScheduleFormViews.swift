import SwiftUI

// MARK: - Team Schedule title suggestion

enum TeamScheduleTitleSuggestion {
    /// Suggested title from Team + opponent / format. Empty when home team name is missing.
    static func suggestedTitle(
        homeTeamName: String,
        opponentName: String?,
        format: GameType,
        languageCode: String?
    ) -> String? {
        let home = homeTeamName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !home.isEmpty else { return nil }
        let policy = FanTeamEventPresentation.policy(for: format)
        if policy.requiresOpponent {
            if let opp = FanTeamScheduleMatchup.trimmedOpponent(opponentName) {
                let vs = L10n.t("fan_team_schedule_vs", languageCode: languageCode)
                return "\(home) \(vs) \(opp)"
            }
            return home
        }
        switch format {
        case .practice, .tryout, .team_meeting, .other, .clinic, .announcement:
            return "\(home) · \(format.displayTitle(languageCode: languageCode))"
        default:
            return home
        }
    }

    /// True when `currentTitle` is empty or still matches a previously auto-generated title.
    static func shouldReplaceTitle(currentTitle: String, lastAutoSuggested: String) -> Bool {
        let trimmed = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if lastAutoSuggested.isEmpty { return false }
        return trimmed == lastAutoSuggested.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Shared chrome (Team Schedule progressive form)

struct TeamScheduleFormSectionCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .textCase(.uppercase)
                .tracking(0.6)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                content()
            }
            .background(FGAdaptiveSurface.cardElevated)
            .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.35 : 0.4), lineWidth: 0.5)
            }
            .softCardShadow()
        }
    }
}

struct TeamScheduleSubtitleRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let systemImage: String
    var accent: Color = FGColor.intentTeams
    let label: String
    var subtitle: String? = nil
    let value: String
    var valueIsPlaceholder: Bool = false
    var showsChevron: Bool = true

    var body: some View {
        HStack(alignment: .center, spacing: FGSpacing.sm) {
            PickupFormIconBadge(systemImage: systemImage, accent: accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: FGSpacing.sm)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(valueIsPlaceholder ? accent : FGColor.secondaryText(colorScheme))
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .minimumScaleFactor(0.8)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 10)
        .frame(minHeight: 44, alignment: .center)
        .contentShape(Rectangle())
    }
}
