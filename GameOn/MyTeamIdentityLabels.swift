import Foundation

/// Compact immutable display model for the authoritative primary “My Team.”
struct MyTeamDisplayModel: Equatable, Sendable {
    let teamID: String
    let teamName: String
    let kind: FavoriteTeamKind
    let sport: FavoriteTeamSport

    /// Pure value mapping from ``FavoriteTeam`` (already `nonisolated` / `Sendable`).
    nonisolated init(team: FavoriteTeam) {
        teamID = team.id
        teamName = team.name
        kind = team.kind
        sport = team.sport
    }

    /// Card secondary line: sport name only (e.g. "Basketball"), not "My Basketball Team".
    func sportLabel(languageCode: String) -> String {
        _ = languageCode
        return sport.chipTitle
    }

    func accessibilityLabel(languageCode: String) -> String {
        let myTeam = L10n.t("my_team", languageCode: languageCode)
        return "\(myTeam), \(teamName), \(sportLabel(languageCode: languageCode))"
    }
}

/// National-fan strip subtitle from the selected national-team identity only.
///
/// Independent of My Team. Today `NationalTeamIdentity` stores country/flag/label
/// but not sport; until a catalog national-team ID is persisted, use the neutral
/// subtitle (never infer sport from My Team, country lists, or tournaments).
enum NationalFanIdentityDisplay {
    /// Neutral subtitle when national country identity exists without sport metadata.
    static func stripSubtitle(languageCode: String) -> String {
        L10n.t("national_team_subtitle", languageCode: languageCode)
    }

    /// Sport-specific subtitle when a structured national-team sport is known.
    /// Pass `nil` when sport is unknown — never falls back to My Team.
    static func stripSubtitle(
        nationalTeamSport: FavoriteTeamSport?,
        languageCode: String
    ) -> String {
        guard let nationalTeamSport else {
            return stripSubtitle(languageCode: languageCode)
        }
        let localized = MyTeamIdentityLabels.nationalTeamSubtitle(
            sport: nationalTeamSport,
            languageCode: languageCode
        )
        let trimmed = localized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != "national_sport_team_format",
              !trimmed.hasPrefix("national_") else {
#if DEBUG
            print("[NationalFanIdentity] omitted sport subtitle sport=\(nationalTeamSport.rawValue)")
#endif
            return stripSubtitle(languageCode: languageCode)
        }
        return trimmed
    }

    static func accessibilityLabel(
        identity: NationalTeamIdentity,
        nationalTeamSport: FavoriteTeamSport? = nil,
        languageCode: String
    ) -> String {
        let heading = L10n.t("national_team", languageCode: languageCode)
        let title = identity.resolvedSupporterLabel(languageCode: languageCode)
        let subtitle = stripSubtitle(nationalTeamSport: nationalTeamSport, languageCode: languageCode)
        return "\(heading), \(title), \(subtitle)"
    }
}

/// Sport-aware permanent subtitles for My Team / national-team identity labels.
/// Uses `FavoriteTeam.kind` / `FavoriteTeam.sport` — never competition/tournament names.
enum MyTeamIdentityLabels {
    static func subtitle(
        kind: FavoriteTeamKind,
        sport: FavoriteTeamSport,
        languageCode: String
    ) -> String {
        if kind == .nationalTeam {
            return nationalTeamSubtitle(sport: sport, languageCode: languageCode)
        }
        return clubMyTeamSubtitle(sport: sport, languageCode: languageCode)
    }

    static func subtitle(for team: FavoriteTeam, languageCode: String) -> String {
        subtitle(kind: team.kind, sport: team.sport, languageCode: languageCode)
    }

    static func nationalTeamSubtitle(sport: FavoriteTeamSport, languageCode: String) -> String {
        switch sport {
        case .soccer:
            return L10n.t("national_soccer_team", languageCode: languageCode)
        case .basketball:
            return L10n.t("national_basketball_team", languageCode: languageCode)
        case .hockey:
            return L10n.t("national_hockey_team", languageCode: languageCode)
        case .rugby:
            return L10n.t("national_rugby_team", languageCode: languageCode)
        case .baseball:
            return L10n.t("national_baseball_team", languageCode: languageCode)
        case .cricket:
            return L10n.t("national_cricket_team", languageCode: languageCode)
        case .football:
            return L10n.t("national_football_team", languageCode: languageCode)
        case .tennis, .badminton, .golf, .combat, .racing, .dance, .ncaa, .olympics:
            return String(
                format: L10n.t("national_sport_team_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                sport.chipTitle
            )
        }
    }

    static func clubMyTeamSubtitle(sport: FavoriteTeamSport, languageCode: String) -> String {
        switch sport {
        case .soccer:
            return L10n.t("my_soccer_team", languageCode: languageCode)
        case .basketball:
            return L10n.t("my_basketball_team", languageCode: languageCode)
        case .football:
            return L10n.t("my_football_team", languageCode: languageCode)
        case .hockey:
            return L10n.t("my_hockey_team", languageCode: languageCode)
        case .baseball:
            return L10n.t("my_baseball_team", languageCode: languageCode)
        case .rugby:
            return L10n.t("my_rugby_team", languageCode: languageCode)
        case .cricket:
            return L10n.t("my_cricket_team", languageCode: languageCode)
        default:
            return String(
                format: L10n.t("my_sport_team_format", languageCode: languageCode),
                locale: Locale(identifier: languageCode),
                sport.chipTitle
            )
        }
    }
}
