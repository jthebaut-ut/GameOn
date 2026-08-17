import Foundation
import SwiftUI

#if DEBUG
enum FanGeoSportMarkSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[FanGeoSportMarkTest] PASS \(name)")
            } else {
                failures += 1
                print("[FanGeoSportMarkTest] FAIL \(name)")
            }
        }

        expect(
            FanGeoSportMarkCatalog.kind(sport: "badminton") == .badminton,
            "badminton resolves shuttlecock mark"
        )
        expect(
            FanGeoSportMarkCatalog.kind(sport: "Soccer") == .soccer,
            "soccer resolves ball mark"
        )
        expect(
            FanGeoSportMarkCatalog.kind(sport: "NBA") == .basketball,
            "NBA token maps to basketball mark"
        )
        expect(
            FanGeoSportMarkCatalog.kind(sport: "NFL") == .football,
            "NFL token maps to football mark"
        )
        expect(
            FanGeoSportMarkCatalog.kind(sport: "Cycling", subtype: "mountain_biking") == .mountainBike,
            "MTB subtype uses mountain bike mark"
        )
        expect(
            FanGeoSportMarkCatalog.kind(sport: "Cycling", subtype: "road_cycling") == .roadCycling,
            "road cycling subtype uses road bike mark"
        )
        expect(
            FanGeoSportMarkCatalog.kind(sport: "Yoga") == .yoga,
            "yoga extra sport has a lotus mark"
        )
        expect(
            FanGeoSportMarkCatalog.kind(sport: "unknown-sport-xyz") == .generic,
            "unknown sport uses generic vector fallback"
        )

        let badminton = FanGeoSportMarkCatalog.descriptor(sport: "Badminton")
        expect(badminton.accentRed > 0.4 && badminton.accentBlue > 0.7, "badminton ring is purple")
        let soccer = FanGeoSportMarkCatalog.descriptor(sport: "Soccer")
        expect(soccer.accentGreen > soccer.accentRed, "soccer ring is green")
        let football = FanGeoSportMarkCatalog.descriptor(sport: "Football")
        expect(football.accentBlue > football.accentRed, "football ring is dark blue")
        let tennis = FanGeoSportMarkCatalog.descriptor(sport: "Tennis")
        expect(tennis.accentGreen > tennis.accentRed, "tennis ring is green")

        for token in AppSportCatalog.sportsExcludingAll {
            let kind = FanGeoSportMarkCatalog.kind(sport: token)
            expect(kind != .generic || SportFilterCatalog.isFallbackSport(token), "catalog sport \(token) has a dedicated or generic mark")
        }

        for kind in FanGeoSportMarkKind.allCases {
            let path = FanGeoSportMarkGlyph(kind: kind).path(in: CGRect(x: 0, y: 0, width: 64, height: 64))
            expect(!path.isEmpty, "glyph \(kind.rawValue) is a non-empty vector path")
        }

        expect(
            FanTeamRecruitingKind.advertised(lookingForPlayers: true) == .players,
            "boolean recruiting maps to players"
        )
        expect(
            FanTeamRecruitingKind.advertised(lookingForPlayers: false) == nil,
            "recruiting off advertises nothing"
        )
        expect(
            FanTeamRecruitingKind.players.localizationKey == "team_discovery_looking_for_players",
            "players uses existing recruiting key"
        )

        let enPlayers = L10n.t("team_discovery_looking_for_players", languageCode: "en")
        expect(enPlayers == "Looking for Players", "en looking for players")
        expect(enPlayers != "team_discovery_looking_for_players", "players key resolves")
        expect(
            L10n.t("team_discovery_looking_for_athletes", languageCode: "en") == "Looking for Athletes",
            "en looking for athletes"
        )
        expect(
            L10n.t("team_discovery_looking_for_fans", languageCode: "en") == "Looking for Fans",
            "en looking for fans"
        )
        expect(
            L10n.t("team_discovery_fan_club_open", languageCode: "en") == "Fan Club Open",
            "en fan club open"
        )
        expect(
            L10n.t("team_discovery_looking_for_athletes", languageCode: "es") != "team_discovery_looking_for_athletes",
            "es athletes key resolves"
        )

        expect(
            FanGeoSportMarkCatalog.compactWordmark(from: "IMC Team") == "IMC TEAM",
            "wordmark keeps two short words"
        )
        expect(
            ChatInboxFanTeamAvatarDecision.preferredSource(logoThumbnailURL: nil, logoURL: nil) == .sportColorMark,
            "no logo still uses sport mark fallback"
        )
        expect(
            ChatInboxFanTeamAvatarDecision.preferredSource(
                logoThumbnailURL: "https://cdn.example/t.jpg",
                logoURL: nil
            ) == .logoThumbnail,
            "uploaded thumbnail still wins"
        )

        if failures == 0 {
            print("[FanGeoSportMarkTest] ALL PASSED")
        } else {
            print("[FanGeoSportMarkTest] FAILURES=\(failures)")
        }
    }
}
#endif
