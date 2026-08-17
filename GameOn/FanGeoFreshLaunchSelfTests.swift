import Foundation

#if DEBUG
enum FanGeoFreshLaunchSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[FreshLaunchTest] PASS \(name)")
            } else {
                failures += 1
                print("[FreshLaunchTest] FAIL \(name)")
            }
        }

        expect(
            FanGeoFreshLaunchRouting.discoverTabRawValue == MainTabView.AppTab.discover.rawValue,
            "fresh launch → Discover → Map"
        )
        expect(
            FanGeoFreshLaunchRouting.mapPresentation == "map",
            "Discover presentation is Map"
        )
        expect(
            FanGeoFreshLaunchRouting.tabAfterTerminateAndRelaunch(
                tabAtTermination: MainTabView.AppTab.following.rawValue,
                hasExplicitDeepLinkOverride: false
            ) == "discover",
            "terminate on My Sports → relaunch Discover Map"
        )
        expect(
            FanGeoFreshLaunchRouting.tabAfterTerminateAndRelaunch(
                tabAtTermination: MainTabView.AppTab.teams.rawValue,
                hasExplicitDeepLinkOverride: false
            ) == "discover",
            "terminate on Teams → relaunch Discover Map"
        )
        expect(
            FanGeoFreshLaunchRouting.tabAfterTerminateAndRelaunch(
                tabAtTermination: MainTabView.AppTab.chat.rawValue,
                hasExplicitDeepLinkOverride: false
            ) == "discover",
            "terminate on Chat → relaunch Discover Map"
        )
        expect(
            FanGeoFreshLaunchRouting.tabAfterTerminateAndRelaunch(
                tabAtTermination: MainTabView.AppTab.account.rawValue,
                hasExplicitDeepLinkOverride: false
            ) == "discover",
            "terminate on Profile → relaunch Discover Map"
        )
        expect(
            FanGeoFreshLaunchRouting.tabAfterTerminateAndRelaunch(
                tabAtTermination: MainTabView.AppTab.calendar.rawValue,
                hasExplicitDeepLinkOverride: false
            ) == "discover",
            "terminate on Schedule → relaunch Discover Map"
        )
        expect(
            FanGeoFreshLaunchRouting.preservesTabAcrossBackgroundForeground(
                selectedBefore: "following",
                selectedAfterSameProcess: "following"
            ),
            "background/foreground while on another tab → stay"
        )
        expect(
            FanGeoFreshLaunchRouting.preservesTabAcrossBackgroundForeground(
                selectedBefore: "teams",
                selectedAfterSameProcess: "discover"
            ) == false,
            "same-process reset to Discover would fail this check"
        )
        expect(
            FanGeoFreshLaunchRouting.tabAfterTerminateAndRelaunch(
                tabAtTermination: "discover",
                hasExplicitDeepLinkOverride: true,
                deepLinkTabRaw: "chat"
            ) == "chat",
            "valid push/deep link on cold launch → destination wins"
        )
        expect(
            FanGeoFreshLaunchRouting.tabAfterTerminateAndRelaunch(
                tabAtTermination: "following",
                hasExplicitDeepLinkOverride: true,
                deepLinkTabRaw: "teams"
            ) == "teams",
            "team event / invitation deep link wins over Discover default"
        )
        expect(
            FanGeoFreshLaunchRouting.shouldRevertStaleSceneRestore(
                restoredRaw: "following",
                committedRaw: "discover"
            ),
            "stale SceneStorage My Sports restore is reverted"
        )
        expect(
            FanGeoFreshLaunchRouting.shouldRevertStaleSceneRestore(
                restoredRaw: "chat",
                committedRaw: "chat"
            ) == false,
            "committed deep-link Chat is not reverted"
        )
        expect(
            FanGeoAuthLandingRouting.replacesRootOnSignedOutLaunch == false,
            "signed-out launch still uses MainTabView / existing auth flow"
        )
        expect(
            FanGeoAuthLandingRouting.isExplicitPresentationOnly,
            "auth landing remains explicit, not the fresh-launch root"
        )
        expect(
            FanGeoAuthLandingRouting.mountsGuestProfileOnSignedOutAccountTab == false,
            "fresh signed-out launch does not mount old guest Profile"
        )
        expect(
            FanGeoAuthLandingRouting.shouldPresentAuthLandingForSignedOutAccountTab(
                isLoggedIn: false,
                isVenueOwnerLoggedIn: false
            ),
            "signed-out Profile tap presents premium landing rather than Discover becoming auth root"
        )

        if failures == 0 {
            print("[FreshLaunchTest] ALL PASSED")
        } else {
            print("[FreshLaunchTest] FAILURES=\(failures)")
            assertionFailure("FanGeoFreshLaunchSelfTests failed: \(failures)")
        }
    }
}
#endif
