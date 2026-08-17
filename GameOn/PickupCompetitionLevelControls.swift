import SwiftUI

/// Shared Competition Level menu used by Pickup create/edit and Team create/edit.
/// Do not duplicate pickers elsewhere — bind to `PickupCompetitionLevel?`.
struct PickupCompetitionLevelMenuPicker: View {
    @Binding var selection: PickupCompetitionLevel?
    let languageCode: String
    var tint: Color? = nil

    var body: some View {
        Picker(selection: $selection) {
            Text(L10n.t("pickup_competition_level_not_specified", languageCode: languageCode))
                .tag(Optional<PickupCompetitionLevel>.none)
            ForEach(PickupCompetitionLevel.allCases) { level in
                Text(level.displayTitle(languageCode: languageCode)).tag(Optional(level))
            }
        } label: {
            EmptyView()
        }
        .labelsHidden()
        .tint(tint)
    }
}

/// Team card / profile meta: `Youth · Soccer · 24 members` (hides level when nil).
enum FanTeamMetaLine {
    static func compose(
        competitionLevel: PickupCompetitionLevel?,
        sport: String,
        memberCount: Int?,
        languageCode: String,
        sportFallbackKey: String = "fan_teams_sport_unspecified"
    ) -> String {
        var parts: [String] = []
        if let competitionLevel {
            parts.append(competitionLevel.displayTitle(languageCode: languageCode))
        }
        let trimmedSport = sport.trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append(
            trimmedSport.isEmpty
                ? L10n.t(sportFallbackKey, languageCode: languageCode)
                : trimmedSport
        )
        if let memberCount {
            parts.append(
                TeamDetailLocalizedFormat.format(
                    "fan_teams_members_count_format",
                    languageCode: languageCode,
                    int64Args: [Int64(memberCount)]
                )
            )
        }
        return parts.joined(separator: " · ")
    }

    /// Compact list line without member count: `Youth · Soccer`.
    static func composeCompact(
        competitionLevel: PickupCompetitionLevel?,
        sport: String,
        languageCode: String
    ) -> String {
        compose(
            competitionLevel: competitionLevel,
            sport: sport,
            memberCount: nil,
            languageCode: languageCode
        )
    }
}

/// Pure helpers for Team → game competition inheritance / override (DEBUG-testable).
enum PickupTeamCompetitionInheritance {
    /// New Team game initial level = Team default (may be nil).
    static func initialGameLevel(teamDefault: PickupCompetitionLevel?) -> PickupCompetitionLevel? {
        teamDefault
    }

    /// Edit: treat matching Team default as inherited (show Inherited chrome until Override).
    static func startsInInheritedMode(
        gameLevel: PickupCompetitionLevel?,
        teamDefault: PickupCompetitionLevel?
    ) -> Bool {
        guard let teamDefault else { return false }
        return gameLevel == teamDefault
    }

    /// CSV: omitted → Team default; explicit parse → override for that row only.
    static func resolveCSVLevel(
        csvRaw: String,
        parsed: PickupCompetitionLevel?,
        teamDefault: PickupCompetitionLevel?,
        isTeamSourced: Bool
    ) -> PickupCompetitionLevel? {
        let trimmed = csvRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return isTeamSourced ? teamDefault : nil
        }
        return parsed
    }
}
