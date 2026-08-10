import Foundation

/// Team-context rules for the shared Pickup CSV importer (no Team-specific parser).
enum PickupBulkImportTeamRules {
    /// Empty CSV sport → Team sport. Conflicting sport → reject with a clear message.
    static func resolveSport(
        csvSportRaw: String,
        team: PickupGameTeamCreationContext?,
        canonicalize: (String) -> String?
    ) -> (sport: String?, error: String?) {
        let trimmedCSV = csvSportRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let team else {
            if trimmedCSV.isEmpty { return (nil, "Missing sport.") }
            if let canon = canonicalize(trimmedCSV) { return (canon, nil) }
            return (nil, nil) // caller adds invalid-sport guidance
        }

        let teamCanon = canonicalize(team.teamSport)
            ?? team.teamSport.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !teamCanon.isEmpty else {
            return (nil, "Team sport is missing.")
        }

        if trimmedCSV.isEmpty {
            return (teamCanon, nil)
        }
        guard let rowCanon = canonicalize(trimmedCSV) else {
            return (nil, nil) // caller adds invalid-sport guidance
        }
        if sportsMatch(rowCanon, teamCanon) {
            return (rowCanon, nil)
        }
        let rowLabel = AppSportCatalog.displayLabel(forSportToken: rowCanon)
        let teamLabel = AppSportCatalog.displayLabel(forSportToken: teamCanon)
        return (
            nil,
            "This game uses \(rowLabel), but \(team.teamName) is a \(teamLabel) Team."
        )
    }

    static func defaultGameFormat(isTeamSourced: Bool) -> GameType {
        isTeamSourced ? GameType.defaultForTeamCreate : GameType.defaultForNormalCreate
    }

    static func allowsGameFormat(_ format: GameType, isTeamSourced: Bool) -> Bool {
        if isTeamSourced {
            return GameType.fanTeamLinkableCases.contains(format)
        }
        return GameType.pickupOrganizerCases.contains(format) || format == .match
    }

    static func gameFormatErrorMessage(for format: GameType, isTeamSourced: Bool) -> String? {
        guard isTeamSourced, !allowsGameFormat(format, isTeamSourced: true) else { return nil }
        return "Team games must use practice, scrimmage, league_game, tournament_game, tryout, clinic, or match. This row uses \(format.rawValue)."
    }

    static func gameFormatGuidance(isTeamSourced: Bool) -> String {
        isTeamSourced
            ? "Use: practice, scrimmage, league_game, tournament_game, tryout, clinic, or match."
            : "Use: pickup, practice, scrimmage, league_game, tournament_game, tryout, or clinic."
    }

    /// Team CSV: `players_needed` means additional outside players (not Team roster size).
    /// Omitted → inactive recruiting floor (`1`, no max). Explicit value → outside recruiting.
    static func resolvePlayersNeeded(
        csvPlayersNeeded: Int?,
        csvRaw: String,
        isTeamSourced: Bool
    ) -> (playersNeeded: Int?, error: String?) {
        if isTeamSourced, csvRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (PickupTeamOutsideRecruiting.inactivePlayersNeededFloor, nil)
        }
        guard let value = csvPlayersNeeded else {
            if csvRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (nil, "Missing players_needed.")
            }
            return (nil, "players_needed must be numeric.")
        }
        guard (1...20).contains(value) else {
            return (nil, "players_needed must be between 1 and 20.")
        }
        return (value, nil)
    }

    private static func sportsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let a = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.localizedCaseInsensitiveCompare(b) == .orderedSame { return true }
        return normalize(a) == normalize(b)
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-z0-9]+", with: "", options: .regularExpression)
    }
}
