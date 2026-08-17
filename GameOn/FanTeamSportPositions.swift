import Foundation

/// Canonical sport position catalogs for Team event lineups + preferred positions.
/// Codes are storage tokens; long titles are localized via `localizedTitleKey`.
enum FanTeamSportPositions {
    struct Position: Hashable, Sendable, Identifiable {
        let code: String
        let localizedTitleKey: String
        var id: String { code }

        func shortLabel() -> String { code }

        func pickerLabel(languageCode: String) -> String {
            let long = L10n.t(localizedTitleKey, languageCode: languageCode)
            return "\(code) · \(long)"
        }

        func accessibilityLabel(languageCode: String) -> String {
            L10n.t(localizedTitleKey, languageCode: languageCode)
        }
    }

    struct Group: Hashable, Sendable, Identifiable {
        let id: String
        let localizedTitleKey: String
        let positions: [Position]
    }

    /// Resolve catalog for a FanGeo sport token (Team sport / event sport).
    static func groups(forSportToken raw: String?) -> [Group] {
        let token = AppSportCatalog.canonicalFormPickerToken(for: raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch token {
        case "soccer", "football soccer":
            return soccerGroups
        case "baseball", "softball":
            return baseballGroups
        case "nba", "basketball":
            return basketballGroups
        case "nfl", "football":
            return americanFootballGroups
        case "nhl", "hockey":
            return hockeyGroups
        case "volleyball":
            return volleyballGroups
        default:
            return []
        }
    }

    static func positions(forSportToken raw: String?) -> [Position] {
        groups(forSportToken: raw).flatMap(\.positions)
    }

    static func position(code: String?, sportToken: String?) -> Position? {
        let normalized = (code ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !normalized.isEmpty else { return nil }
        return positions(forSportToken: sportToken).first { $0.code == normalized }
    }

    static func supportsPositions(forSportToken raw: String?) -> Bool {
        !groups(forSportToken: raw).isEmpty
    }

    static func isValid(code: String?, sportToken: String?) -> Bool {
        guard let code, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true // null/empty allowed
        }
        return position(code: code, sportToken: sportToken) != nil
    }

    // MARK: Soccer

    private static let soccerGroups: [Group] = [
        Group(
            id: "gk",
            localizedTitleKey: "fan_team_position_group_goalkeeper",
            positions: [
                Position(code: "GK", localizedTitleKey: "fan_team_position_gk")
            ]
        ),
        Group(
            id: "def",
            localizedTitleKey: "fan_team_position_group_defense",
            positions: [
                Position(code: "LB", localizedTitleKey: "fan_team_position_lb"),
                Position(code: "CB", localizedTitleKey: "fan_team_position_cb"),
                Position(code: "RB", localizedTitleKey: "fan_team_position_rb"),
                Position(code: "LWB", localizedTitleKey: "fan_team_position_lwb"),
                Position(code: "RWB", localizedTitleKey: "fan_team_position_rwb"),
                Position(code: "DEF", localizedTitleKey: "fan_team_position_def"),
            ]
        ),
        Group(
            id: "mid",
            localizedTitleKey: "fan_team_position_group_midfield",
            positions: [
                Position(code: "CDM", localizedTitleKey: "fan_team_position_cdm"),
                Position(code: "CM", localizedTitleKey: "fan_team_position_cm"),
                Position(code: "CAM", localizedTitleKey: "fan_team_position_cam"),
                Position(code: "LM", localizedTitleKey: "fan_team_position_lm"),
                Position(code: "RM", localizedTitleKey: "fan_team_position_rm"),
                Position(code: "MID", localizedTitleKey: "fan_team_position_mid"),
            ]
        ),
        Group(
            id: "att",
            localizedTitleKey: "fan_team_position_group_attack",
            positions: [
                Position(code: "LW", localizedTitleKey: "fan_team_position_lw"),
                Position(code: "RW", localizedTitleKey: "fan_team_position_rw"),
                Position(code: "CF", localizedTitleKey: "fan_team_position_cf"),
                Position(code: "ST", localizedTitleKey: "fan_team_position_st"),
                Position(code: "FWD", localizedTitleKey: "fan_team_position_fwd"),
            ]
        ),
    ]

    static let soccerFormations: [String] = [
        "4-4-2", "4-3-3", "4-2-3-1", "3-5-2", "4-1-4-1", "3-4-3", "5-3-2"
    ]

    // MARK: Baseball / Softball

    private static let baseballGroups: [Group] = [
        Group(
            id: "baseball_battery",
            localizedTitleKey: "fan_team_position_group_pitcher_catcher",
            positions: [
                Position(code: "P", localizedTitleKey: "fan_team_position_p"),
                Position(code: "C", localizedTitleKey: "fan_team_position_c_baseball"),
            ]
        ),
        Group(
            id: "baseball_infield",
            localizedTitleKey: "fan_team_position_group_infield",
            positions: [
                Position(code: "1B", localizedTitleKey: "fan_team_position_1b"),
                Position(code: "2B", localizedTitleKey: "fan_team_position_2b"),
                Position(code: "3B", localizedTitleKey: "fan_team_position_3b"),
                Position(code: "SS", localizedTitleKey: "fan_team_position_ss"),
            ]
        ),
        Group(
            id: "baseball_outfield",
            localizedTitleKey: "fan_team_position_group_outfield",
            positions: [
                Position(code: "LF", localizedTitleKey: "fan_team_position_lf"),
                Position(code: "CF", localizedTitleKey: "fan_team_position_cf_baseball"),
                Position(code: "RF", localizedTitleKey: "fan_team_position_rf"),
            ]
        ),
        Group(
            id: "baseball_dh",
            localizedTitleKey: "fan_team_position_group_dh",
            positions: [
                Position(code: "DH", localizedTitleKey: "fan_team_position_dh"),
            ]
        ),
    ]

    // MARK: Basketball

    private static let basketballGroups: [Group] = [
        Group(
            id: "basketball_guards",
            localizedTitleKey: "fan_team_position_group_guards",
            positions: [
                Position(code: "PG", localizedTitleKey: "fan_team_position_pg"),
                Position(code: "SG", localizedTitleKey: "fan_team_position_sg"),
            ]
        ),
        Group(
            id: "basketball_forwards",
            localizedTitleKey: "fan_team_position_group_forwards",
            positions: [
                Position(code: "SF", localizedTitleKey: "fan_team_position_sf"),
                Position(code: "PF", localizedTitleKey: "fan_team_position_pf"),
            ]
        ),
        Group(
            id: "basketball_center",
            localizedTitleKey: "fan_team_position_group_center",
            positions: [
                Position(code: "C", localizedTitleKey: "fan_team_position_c_basketball"),
            ]
        ),
    ]

    // MARK: American Football

    private static let americanFootballGroups: [Group] = [
        Group(
            id: "football_offense",
            localizedTitleKey: "fan_team_position_group_offense",
            positions: [
                Position(code: "QB", localizedTitleKey: "fan_team_position_qb"),
                Position(code: "RB", localizedTitleKey: "fan_team_position_rb_fb"),
                Position(code: "WR", localizedTitleKey: "fan_team_position_wr"),
                Position(code: "TE", localizedTitleKey: "fan_team_position_te"),
                Position(code: "OL", localizedTitleKey: "fan_team_position_ol"),
            ]
        ),
        Group(
            id: "football_defense",
            localizedTitleKey: "fan_team_position_group_defense",
            positions: [
                Position(code: "DL", localizedTitleKey: "fan_team_position_dl"),
                Position(code: "LB", localizedTitleKey: "fan_team_position_lb_fb"),
                Position(code: "CB", localizedTitleKey: "fan_team_position_cb_fb"),
                Position(code: "S", localizedTitleKey: "fan_team_position_s_fb"),
            ]
        ),
        Group(
            id: "football_special",
            localizedTitleKey: "fan_team_position_group_special_teams",
            positions: [
                Position(code: "K", localizedTitleKey: "fan_team_position_k"),
                Position(code: "P", localizedTitleKey: "fan_team_position_p_fb"),
            ]
        ),
    ]

    // MARK: Hockey

    private static let hockeyGroups: [Group] = [
        Group(
            id: "hockey_g",
            localizedTitleKey: "fan_team_position_group_goaltender",
            positions: [
                Position(code: "G", localizedTitleKey: "fan_team_position_g"),
            ]
        ),
        Group(
            id: "hockey_def",
            localizedTitleKey: "fan_team_position_group_defense",
            positions: [
                Position(code: "LD", localizedTitleKey: "fan_team_position_ld"),
                Position(code: "RD", localizedTitleKey: "fan_team_position_rd"),
            ]
        ),
        Group(
            id: "hockey_fwd",
            localizedTitleKey: "fan_team_position_group_forwards",
            positions: [
                Position(code: "C", localizedTitleKey: "fan_team_position_c_hockey"),
                Position(code: "LW", localizedTitleKey: "fan_team_position_lw_hockey"),
                Position(code: "RW", localizedTitleKey: "fan_team_position_rw_hockey"),
            ]
        ),
    ]

    // MARK: Volleyball

    private static let volleyballGroups: [Group] = [
        Group(
            id: "vb_setters",
            localizedTitleKey: "fan_team_position_group_setters",
            positions: [
                Position(code: "S", localizedTitleKey: "fan_team_position_s_vb"),
            ]
        ),
        Group(
            id: "vb_hitters",
            localizedTitleKey: "fan_team_position_group_hitters",
            positions: [
                Position(code: "OH", localizedTitleKey: "fan_team_position_oh"),
                Position(code: "OPP", localizedTitleKey: "fan_team_position_opp"),
            ]
        ),
        Group(
            id: "vb_middle",
            localizedTitleKey: "fan_team_position_group_middle",
            positions: [
                Position(code: "MB", localizedTitleKey: "fan_team_position_mb"),
            ]
        ),
        Group(
            id: "vb_libero",
            localizedTitleKey: "fan_team_position_group_libero_defense",
            positions: [
                Position(code: "L", localizedTitleKey: "fan_team_position_l_vb"),
                Position(code: "DS", localizedTitleKey: "fan_team_position_ds"),
            ]
        ),
    ]
}
