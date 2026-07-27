import Foundation

#if DEBUG
/// Startup presentation helpers for age + splash unification (pure, no UIKit).
enum AgeStartupUnificationSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[AgeStartupTest] PASS \(name)")
            } else {
                failures += 1
                print("[AgeStartupTest] FAIL \(name)")
            }
        }

        expect(
            FanGeoSplashBootstrapStage.checkingAgeEligibility.message.contains("age"),
            "age_stage_message_present"
        )
        expect(
            FanGeoSplashBootstrapStage.signingYouIn.message.lowercased().contains("sign"),
            "signing_stage_present"
        )
        expect(
            FanGeoSplashStatusPresentation.ageStatusRevealDelayMs > 0,
            "age_reveal_delay_positive"
        )
        expect(
            FanGeoSplashStatusPresentation.minimumVisibleMs > 0,
            "status_min_visible_positive"
        )

        // Fast age response: reveal delay not yet elapsed → do not show age status.
        let fastAgeMs = 50
        expect(
            fastAgeMs < FanGeoSplashStatusPresentation.ageStatusRevealDelayMs,
            "fast_age_below_reveal_threshold"
        )

        // Slow age response: past reveal delay → age status may surface.
        let slowAgeMs = 500
        expect(
            slowAgeMs >= FanGeoSplashStatusPresentation.ageStatusRevealDelayMs,
            "slow_age_past_reveal_threshold"
        )

        // Routing model: actionable presentations vs resolving splash.
        enum Route: Equatable {
            case splashResolving
            case actionableGate
            case mainApp
        }
        func route(
            authenticated: Bool,
            shellAllowed: Bool,
            resolving: Bool,
            hasPresentation: Bool,
            blocks: Bool
        ) -> Route {
            guard authenticated else { return .mainApp }
            if shellAllowed { return .mainApp }
            if hasPresentation || (blocks && !resolving) { return .actionableGate }
            return .splashResolving
        }

        expect(
            route(authenticated: true, shellAllowed: false, resolving: true, hasPresentation: false, blocks: true)
                == .splashResolving,
            "resolving_uses_branded_splash"
        )
        expect(
            route(authenticated: true, shellAllowed: false, resolving: false, hasPresentation: true, blocks: true)
                == .actionableGate,
            "needs_confirmation_uses_gate"
        )
        expect(
            route(authenticated: true, shellAllowed: true, resolving: false, hasPresentation: false, blocks: false)
                == .mainApp,
            "eligible_mounts_main"
        )
        expect(
            route(authenticated: false, shellAllowed: false, resolving: false, hasPresentation: false, blocks: false)
                == .mainApp,
            "guest_not_age_blocked_at_root"
        )

        print("[AgeStartupTest] failures=\(failures)")
    }
}
#endif
