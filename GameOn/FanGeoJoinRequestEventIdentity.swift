import Foundation

/// Shared Event identity + capacity lines for Join Request Action Center cards
/// and the organizer Request Review screen. Reuses Team/Pickup title, matchup,
/// and recruiting-capacity rules — no new card design.
enum FanGeoJoinRequestEventIdentity {
    /// Distinctive name the organizer/requester should recognize first.
    static func primaryTitle(
        gameTitle: String,
        eventTypeLabel: String?,
        matchupLabel: String?,
        languageCode: String
    ) -> String {
        let title = gameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = eventTypeLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let matchup = matchupLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty, title.caseInsensitiveCompare(type) != .orderedSame {
            return title
        }
        if !matchup.isEmpty {
            return matchup
        }
        if !title.isEmpty {
            return title
        }
        if !type.isEmpty {
            return type
        }
        return L10n.t("Pickup", languageCode: languageCode)
    }

    /// Show numeric capacity when the event actually has a preferred/max roster.
    static func showsCapacity(
        maxPlayers: Int?,
        playersNeeded: Int,
        isTeamLinked: Bool
    ) -> Bool {
        if let maxPlayers, maxPlayers > 0 { return true }
        if isTeamLinked {
            return PickupTeamOutsideRecruiting.isEnabled(
                playersNeeded: playersNeeded,
                maxPlayers: maxPlayers
            )
        }
        return playersNeeded > 0
    }

    static func isAtCapacity(
        approvedJoinCount: Int?,
        maxPlayers: Int?,
        playersNeeded: Int,
        isTeamLinked: Bool
    ) -> Bool {
        guard showsCapacity(
            maxPlayers: maxPlayers,
            playersNeeded: playersNeeded,
            isTeamLinked: isTeamLinked
        ) else { return false }
        guard let cap = capacityMax(maxPlayers: maxPlayers, playersNeeded: playersNeeded) else {
            return false
        }
        return max(0, approvedJoinCount ?? 0) >= cap
    }

    static func capacityLabel(
        approvedJoinCount: Int?,
        maxPlayers: Int?,
        playersNeeded: Int,
        isTeamLinked: Bool,
        languageCode: String
    ) -> String? {
        guard showsCapacity(
            maxPlayers: maxPlayers,
            playersNeeded: playersNeeded,
            isTeamLinked: isTeamLinked
        ) else { return nil }
        guard let cap = capacityMax(maxPlayers: maxPlayers, playersNeeded: playersNeeded) else {
            return nil
        }
        let filled = max(0, approvedJoinCount ?? 0)
        let locale = Locale(identifier: L10n.normalizedLanguageCode(languageCode))
        if filled >= cap {
            return String(
                format: L10n.t("pickup_join_capacity_full_format", languageCode: languageCode),
                locale: locale,
                Int64(filled),
                Int64(cap)
            )
        }
        return String(
            format: L10n.t("pickup_join_capacity_players_format", languageCode: languageCode),
            locale: locale,
            Int64(filled),
            Int64(cap)
        )
    }

    static func capacityMax(maxPlayers: Int?, playersNeeded: Int) -> Int? {
        if let maxPlayers, maxPlayers > 0 { return maxPlayers }
        if playersNeeded > 0 { return playersNeeded }
        return nil
    }

    static func matchupLabel(
        homeTeamName: String?,
        opponentName: String?,
        languageCode: String
    ) -> String? {
        FanTeamScheduleMatchup.matchupLine(
            homeTeamName: homeTeamName ?? "",
            opponentName: opponentName,
            languageCode: languageCode
        )
    }
}

#if DEBUG
enum FanGeoJoinRequestEventIdentitySelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[JoinRequestIdentityTest] PASS \(name)")
            } else {
                failures += 1
                print("[JoinRequestIdentityTest] FAIL \(name)")
            }
        }

        expect(
            FanGeoJoinRequestEventIdentity.primaryTitle(
                gameTitle: "Friday Night Practice",
                eventTypeLabel: "Practice",
                matchupLabel: nil,
                languageCode: "en"
            ) == "Friday Night Practice",
            "custom title beats event type"
        )
        expect(
            FanGeoJoinRequestEventIdentity.primaryTitle(
                gameTitle: "League Game",
                eventTypeLabel: "League Game",
                matchupLabel: "JT vs Brighton FC",
                languageCode: "en"
            ) == "JT vs Brighton FC",
            "matchup used when title equals type"
        )
        expect(
            FanGeoJoinRequestEventIdentity.primaryTitle(
                gameTitle: "",
                eventTypeLabel: nil,
                matchupLabel: nil,
                languageCode: "en"
            ) == "Pickup",
            "standalone fallback"
        )
        expect(
            FanGeoJoinRequestEventIdentity.capacityLabel(
                approvedJoinCount: 5,
                maxPlayers: 6,
                playersNeeded: 6,
                isTeamLinked: false,
                languageCode: "en"
            ) == "5 / 6 players",
            "open capacity"
        )
        expect(
            FanGeoJoinRequestEventIdentity.capacityLabel(
                approvedJoinCount: 6,
                maxPlayers: 6,
                playersNeeded: 6,
                isTeamLinked: false,
                languageCode: "en"
            ) == "6 / 6 Full",
            "full capacity"
        )
        expect(
            FanGeoJoinRequestEventIdentity.isAtCapacity(
                approvedJoinCount: 6,
                maxPlayers: 6,
                playersNeeded: 6,
                isTeamLinked: false
            ),
            "at capacity flag"
        )
        expect(
            FanGeoJoinRequestEventIdentity.capacityLabel(
                approvedJoinCount: 0,
                maxPlayers: nil,
                playersNeeded: 1,
                isTeamLinked: true,
                languageCode: "en"
            ) == nil,
            "Team recruiting OFF does not show capacity"
        )

        if failures == 0 {
            print("[JoinRequestIdentityTest] ALL PASSED")
        } else {
            print("[JoinRequestIdentityTest] FAILURES=\(failures)")
            assertionFailure("FanGeoJoinRequestEventIdentitySelfTests failed: \(failures)")
        }
    }
}
#endif
