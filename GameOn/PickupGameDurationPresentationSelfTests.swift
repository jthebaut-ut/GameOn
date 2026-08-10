import Foundation

#if DEBUG
/// DEBUG self-tests for compact pickup duration labels (`45m`, `1h 30m`, `2h`).
enum PickupGameDurationPresentationSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[PickupDurationTest] PASS \(name)")
            } else {
                failures += 1
                print("[PickupDurationTest] FAIL \(name)")
            }
        }

        let en = "en"
        expect(
            PickupGameDurationPresentation.compactLabel(totalMinutes: 30, languageCode: en) == "30m",
            "30m"
        )
        expect(
            PickupGameDurationPresentation.compactLabel(totalMinutes: 45, languageCode: en) == "45m",
            "45m"
        )
        expect(
            PickupGameDurationPresentation.compactLabel(totalMinutes: 60, languageCode: en) == "1h",
            "1h"
        )
        expect(
            PickupGameDurationPresentation.compactLabel(totalMinutes: 90, languageCode: en) == "1h 30m",
            "1h_30m"
        )
        expect(
            PickupGameDurationPresentation.compactLabel(totalMinutes: 120, languageCode: en) == "2h",
            "2h"
        )
        expect(
            PickupGameDurationPresentation.compactLabel(totalMinutes: 135, languageCode: en) == "2h 15m",
            "2h_15m"
        )
        expect(
            PickupGameDurationPresentation.compactLabel(totalMinutes: 0, languageCode: en) == nil,
            "zero_nil"
        )
        expect(
            PickupGameDurationPresentation.compactLabel(totalMinutes: -5, languageCode: en) == nil,
            "negative_nil"
        )
        expect(
            PickupGameDurationPresentation.compactLabel(totalMinutes: 120, languageCode: en)?.contains("game") != true,
            "no_game_suffix"
        )
        expect(
            PickupGameDurationPresentation.compactLabel(totalMinutes: 120, languageCode: "pl") == "2g",
            "pl_hours_unit"
        )
        expect(
            PickupGameDurationPresentation.spokenLabel(totalMinutes: 120, languageCode: en)?.localizedCaseInsensitiveContains("hour") == true,
            "spoken_2h"
        )
        expect(
            PickupGameDurationPresentation.spokenLabel(totalMinutes: 45, languageCode: en)?.localizedCaseInsensitiveContains("minute") == true,
            "spoken_45m"
        )

        if failures == 0 {
            print("[PickupDurationTest] ALL PASSED")
        } else {
            print("[PickupDurationTest] FAILURES=\(failures)")
        }
    }
}
#endif
