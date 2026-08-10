import Foundation
import SwiftUI

#if DEBUG
enum FanTeamColorThemeSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[FanTeamColorThemeTest] PASS \(name)")
            } else {
                failures += 1
                print("[FanTeamColorThemeTest] FAIL \(name)")
            }
        }

        expect(!FanTeamColorTheme.hasCustomColor(nil), "nil color → no tint")
        expect(!FanTeamColorTheme.hasCustomColor(""), "empty color → no tint")
        expect(!FanTeamColorTheme.hasCustomColor("not-a-color"), "invalid color → no tint")
        expect(FanTeamColorTheme.hasCustomColor("#22C25A"), "preset green tints")
        expect(FanTeamColorTheme.hasCustomColor("#FF3B30"), "preset red tints")
        expect(FanTeamColorTheme.hasCustomColor("2F6BFF"), "hex without # tints after normalize")

        expect(
            FanTeamColorTheme.accentColor(colorHex: "#1C1C1E", colorScheme: .dark) != nil,
            "near-black still produces dark-mode accent"
        )
        expect(
            FanTeamColorTheme.accentColor(colorHex: "#FFFFFF", colorScheme: .light) != nil,
            "near-white still produces light-mode accent"
        )

        expect(FanTeamColorTheme.tintOpacity(for: .light) >= 0.05, "light tint >= 5%")
        expect(FanTeamColorTheme.tintOpacity(for: .light) <= 0.08, "light tint <= 8%")
        expect(FanTeamColorTheme.tintOpacity(for: .dark) >= 0.05, "dark tint floor")
        expect(FanTeamColorTheme.tintOpacity(for: .dark) <= 0.12, "dark tint ceiling")
        expect(FanTeamColorTheme.strokeOpacity(for: .light) >= 0.10, "light stroke >= 10%")
        expect(FanTeamColorTheme.strokeOpacity(for: .light) <= 0.15, "light stroke <= 15%")

        let discoverNil = FanTeamColorTheme.pickupDiscoverPreviewAccent(colorHex: nil, colorScheme: .light)
        let discoverBad = FanTeamColorTheme.pickupDiscoverPreviewAccent(colorHex: "nope", colorScheme: .dark)
        let discoverValid = FanTeamColorTheme.pickupDiscoverPreviewAccent(colorHex: "#7B61FF", colorScheme: .light)
        expect(discoverNil == FGColor.intentPlay, "discover nil → FanGeo Play orange")
        expect(discoverBad == FGColor.intentPlay, "discover invalid → FanGeo Play orange")
        expect(discoverValid != FGColor.intentPlay, "discover valid custom ≠ orange fallback")
        expect(
            FanTeamColorTheme.accentColor(colorHex: "#7B61FF", colorScheme: .light) != nil,
            "purple hex parses for discover accent path"
        )
        expect(
            FanTeamColorTheme.discoverPreviewWashOpacity(for: .light) >= 0.08
                && FanTeamColorTheme.discoverPreviewWashOpacity(for: .light) <= 0.14,
            "discover wash light restrained"
        )
        expect(
            FanTeamColorTheme.discoverPreviewWashOpacity(for: .dark) >= 0.10
                && FanTeamColorTheme.discoverPreviewWashOpacity(for: .dark) <= 0.18,
            "discover wash dark restrained"
        )
        expect(
            FanTeamColorTheme.discoverPreviewStrokeOpacity(for: .light)
                > FanTeamColorTheme.discoverPreviewWashOpacity(for: .light),
            "discover stroke stronger than wash"
        )

        if failures == 0 {
            print("[FanTeamColorThemeTest] ALL PASSED")
        } else {
            print("[FanTeamColorThemeTest] FAILURES=\(failures)")
        }
    }
}
#endif
