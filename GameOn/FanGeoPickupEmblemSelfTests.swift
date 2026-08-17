import Foundation

#if DEBUG
enum FanGeoPickupEmblemSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[FanGeoPickupEmblemTest] PASS \(name)")
            } else {
                failures += 1
                print("[FanGeoPickupEmblemTest] FAIL \(name)")
            }
        }

        let now = Date()
        expect(
            FanGeoPickupEmblemStatus.resolve(
                hasStarted: true,
                hasEnded: false,
                isFull: true,
                openSlots: 0,
                createdAt: now,
                now: now
            ) == .live,
            "in-progress game is LIVE even if full"
        )
        expect(
            FanGeoPickupEmblemStatus.resolve(
                hasStarted: true,
                hasEnded: true,
                isFull: false,
                openSlots: 2,
                createdAt: now.addingTimeInterval(-3600),
                now: now
            ) == .started,
            "started-and-ended shows Started"
        )
        expect(
            FanGeoPickupEmblemStatus.resolve(
                hasStarted: false,
                hasEnded: false,
                isFull: true,
                openSlots: 0,
                createdAt: now,
                now: now
            ) == .full,
            "unstarted full roster is FULL"
        )
        expect(
            FanGeoPickupEmblemStatus.resolve(
                hasStarted: false,
                hasEnded: false,
                isFull: false,
                openSlots: 2,
                createdAt: now.addingTimeInterval(-48 * 3600),
                now: now
            ) == .fewSpots,
            "2 open slots is Few Spots"
        )
        expect(
            FanGeoPickupEmblemStatus.resolve(
                hasStarted: false,
                hasEnded: false,
                isFull: false,
                openSlots: 8,
                createdAt: now.addingTimeInterval(-2 * 3600),
                now: now
            ) == .newGame,
            "recent create with plenty of spots is New"
        )
        expect(
            FanGeoPickupEmblemStatus.resolve(
                hasStarted: false,
                hasEnded: false,
                isFull: false,
                openSlots: 8,
                createdAt: now.addingTimeInterval(-48 * 3600),
                now: now
            ) == nil,
            "older open game has no emblem bubble"
        )

        expect(
            FanGeoSportMarkCatalog.kind(sport: "Basketball") == .basketball,
            "pickup basketball uses basketball glyph"
        )
        expect(
            FanGeoSportMarkCatalog.kind(sport: "Disc Golf") == .discGolf,
            "disc golf has a dedicated glyph"
        )
        expect(
            FanGeoSportMarkCatalog.kind(sport: "Hiking") == .hiking,
            "hiking has a dedicated glyph"
        )
        expect(
            FanGeoSportMarkCatalog.kind(sport: "Kayaking") == .kayaking,
            "kayaking has a dedicated glyph"
        )
        expect(
            FanGeoSportMarkCatalog.kind(sport: "Surfing") == .surfing,
            "surfing has a dedicated glyph"
        )
        expect(
            FanGeoSportMarkCatalog.kind(sport: "Cycling", subtype: "mountain_biking") == .mountainBike,
            "MTB subtype still maps for pickup emblems"
        )

        let enBadge = L10n.t("discover_pickup_card_format_badge", languageCode: "en")
        expect(enBadge == "Pickup Game", "en Pickup Game pill")
        expect(enBadge != "discover_pickup_card_format_badge", "pill key resolves")
        expect(L10n.t("discover_pickup_emblem_started", languageCode: "en") == "Started", "en Started")
        expect(L10n.t("discover_pickup_emblem_live", languageCode: "en") == "LIVE", "en LIVE")
        expect(L10n.t("discover_pickup_emblem_full", languageCode: "en") == "FULL", "en FULL")
        expect(L10n.t("discover_pickup_emblem_few_spots", languageCode: "en") == "Few Spots", "en Few Spots")
        expect(L10n.t("discover_pickup_emblem_new", languageCode: "en") == "New", "en New")
        expect(
            L10n.t("discover_pickup_card_format_badge", languageCode: "es") != "discover_pickup_card_format_badge",
            "es pill resolves"
        )

        if failures == 0 {
            print("[FanGeoPickupEmblemTest] ALL PASSED")
        } else {
            print("[FanGeoPickupEmblemTest] FAILURES=\(failures)")
        }
    }
}
#endif
