import Foundation

#if DEBUG
enum SignedOutLandingSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[SignedOutLandingTest] PASS \(name)")
            } else {
                failures += 1
                print("[SignedOutLandingTest] FAIL \(name)")
            }
        }

        expect(
            FanGeoAuthLandingRouting.replacesRootOnSignedOutLaunch == false,
            "signed-out fresh launch does not replace MainTabView with landing"
        )
        expect(
            FanGeoAuthLandingRouting.isExplicitPresentationOnly,
            "auth landing is explicit presentation only"
        )
        expect(
            FanGeoAuthLandingRouting.freshLaunchTabRawValue == MainTabView.AppTab.discover.rawValue,
            "fresh launch tab is Discover Map"
        )
        expect(
            FanGeoAuthLandingRouting.freshLaunchTabRawValue == "discover",
            "signed-in and signed-out fresh launch both Discover"
        )
        expect(
            FanGeoAuthLandingRouting.includesGuestAction == false,
            "no guest action exists"
        )
        expect(
            FanGeoAuthLandingRouting.backgroundAssetName == "StadiumHeroBackground",
            "stadium/soccer-ball background asset"
        )
        expect(
            FanGeoAuthLandingRouting.brandMarkWhiteAssetName == "FanGeoBrandMarkWhite",
            "transparent white FanGeo mark"
        )
        expect(
            FanGeoAuthLandingRouting.brandMarkDarkAssetName == "FanGeoBrandMarkDark",
            "transparent dark FanGeo mark"
        )

        expect(L10n.t("landing_headline_find_your_game", languageCode: "en") == "Find your game.", "headline game")
        expect(L10n.t("landing_headline_find_your_people", languageCode: "en") == "Find your people.", "headline people")
        expect(
            L10n.t("landing_subtitle", languageCode: "en")
                == "Discover watch parties, pickup games, and local fans around you.",
            "subtitle"
        )
        expect(L10n.t("Sign In", languageCode: "en") == "Sign In", "Sign In")
        expect(L10n.t("Create Account", languageCode: "en") == "Create Account", "Create Account")
        expect(L10n.t("landing_sign_in_fan_user", languageCode: "en") == "FanGeo User", "FanGeo User")
        expect(L10n.t("Business", languageCode: "en") == "Business", "Business")
        expect(
            L10n.t("landing_sign_in_chooser_subtitle", languageCode: "en") == "Choose how you use FanGeo.",
            "chooser subtitle"
        )
        expect(L10n.t("Cancel", languageCode: "en") == "Cancel", "Cancel")
        expect(L10n.t("Close", languageCode: "en") == "Close", "Close dismisses landing")

        expect(
            FanGeoAuthLandingRouting.mountsGuestProfileOnSignedOutAccountTab == false,
            "old guest Profile is not mounted on signed-out Profile tab"
        )
        expect(
            FanGeoAuthLandingRouting.shouldPresentAuthLandingForSignedOutAccountTab(
                isLoggedIn: false,
                isVenueOwnerLoggedIn: false
            ),
            "signed-out Profile tap → premium auth landing"
        )
        expect(
            FanGeoAuthLandingRouting.shouldPresentAuthLandingForSignedOutAccountTab(
                isLoggedIn: true,
                isVenueOwnerLoggedIn: false
            ) == false,
            "signed-in fan Profile is unchanged"
        )
        expect(
            FanGeoAuthLandingRouting.shouldPresentAuthLandingForSignedOutAccountTab(
                isLoggedIn: false,
                isVenueOwnerLoggedIn: true
            ) == false,
            "signed-in business Profile is unchanged"
        )
        expect(
            FanGeoAuthLandingRouting.shouldPresentAuthLandingForSignedOutAccountTab(
                isLoggedIn: false,
                isVenueOwnerLoggedIn: false,
                resolvingEmailConfirmation: true
            ) == false,
            "email confirmation can still use Account spinner"
        )
        expect(
            FanGeoAuthLandingRouting.tabAfterDismissingSignedOutProfileAuthLanding(
                previousTabRaw: "discover"
            ) == "discover",
            "close returns to Discover"
        )
        expect(
            FanGeoAuthLandingRouting.tabAfterDismissingSignedOutProfileAuthLanding(
                previousTabRaw: "following"
            ) == "following",
            "close returns to previous public tab"
        )
        expect(
            FanGeoAuthLandingRouting.tabAfterDismissingSignedOutProfileAuthLanding(
                previousTabRaw: "account"
            ) == "discover",
            "close does not leave Profile selected"
        )
        expect(
            FanGeoAuthLandingRouting.shouldSelectAccountAfterSuccessfulAuth(source: .profileTab),
            "Profile-tab sign-in continues to authenticated Profile"
        )
        expect(
            FanGeoAuthLandingRouting.shouldSelectAccountAfterSuccessfulAuth(source: .authGate) == false,
            "auth-gate sign-in stays on the public tab"
        )
        expect(
            FanGeoAuthLandingRouting.shouldSelectAccountAfterSuccessfulAuth(source: .none) == false,
            "no source does not force Profile after auth"
        )

        expect(
            FanGeoAuthLandingRouting.canPresentAuthLanding(
                isLoggedIn: true,
                isVenueOwnerLoggedIn: false
            ) == false,
            "authenticated fan cannot present signed-out landing"
        )
        expect(
            FanGeoAuthLandingRouting.canPresentAuthLanding(
                isLoggedIn: false,
                isVenueOwnerLoggedIn: true
            ) == false,
            "authenticated business cannot present signed-out landing"
        )
        expect(
            FanGeoAuthLandingRouting.canPresentAuthLanding(
                isLoggedIn: false,
                isVenueOwnerLoggedIn: false
            ),
            "signed-out session can present landing"
        )
        expect(
            FanGeoAuthLandingRouting.isLandingPresentedAfterSuccessfulAuthentication() == false,
            "Profile/auth-gate/create-account success dismisses landing"
        )
        expect(
            FanGeoAuthLandingRouting.shouldHonorPresentationWrite(
                requestedPresent: true,
                isLoggedIn: true,
                isVenueOwnerLoggedIn: false
            ) == false,
            "stale fullScreenCover bounce cannot re-present after fan sign-in"
        )
        expect(
            FanGeoAuthLandingRouting.shouldHonorPresentationWrite(
                requestedPresent: true,
                isLoggedIn: false,
                isVenueOwnerLoggedIn: true
            ) == false,
            "stale fullScreenCover bounce cannot re-present after business sign-in"
        )
        expect(
            FanGeoAuthLandingRouting.shouldHonorPresentationWrite(
                requestedPresent: true,
                isLoggedIn: false,
                isVenueOwnerLoggedIn: false
            ),
            "signed-out presentation write is still honored"
        )
        expect(
            FanGeoAuthLandingRouting.shouldHonorPresentationWrite(
                requestedPresent: false,
                isLoggedIn: false,
                isVenueOwnerLoggedIn: false
            ),
            "X / cancel still dismisses the landing without signing in"
        )
        expect(
            FanGeoAuthLandingRouting.shouldHonorPresentationWrite(
                requestedPresent: false,
                isLoggedIn: true,
                isVenueOwnerLoggedIn: false
            ),
            "dismiss write is always honored after authentication"
        )
        expect(
            FanGeoAuthLandingRouting.shouldPresentAuthLandingForSignedOutAccountTab(
                isLoggedIn: true,
                isVenueOwnerLoggedIn: false
            ) == false,
            "auth gate from another tab cannot re-present landing after login"
        )
        expect(
            FanGeoAuthLandingRouting.canPresentAuthLanding(
                isLoggedIn: false,
                isVenueOwnerLoggedIn: false,
                resolvingEmailConfirmation: true
            ) == false,
            "email confirmation is not dismissed into an invalid authenticated landing"
        )

        expect(
            L10n.t("landing_headline_find_your_game", languageCode: "en")
                .localizedCaseInsensitiveContains("Find Your Sports Community") == false,
            "landing is not the old guest Profile headline"
        )
        expect(
            L10n.t("landing_subtitle", languageCode: "en")
                .localizedCaseInsensitiveContains("Explore FanGeo") == false,
            "landing is not Explore FanGeo"
        )
        expect(
            L10n.t("landing_subtitle", languageCode: "en")
                .localizedCaseInsensitiveContains("Watch Live With Fans") == false,
            "landing is not Watch Live With Fans"
        )
        expect(
            L10n.t("landing_subtitle", languageCode: "en")
                .localizedCaseInsensitiveContains("Join Pickup Games") == false,
            "landing is not Join Pickup Games"
        )
        expect(
            L10n.t("landing_subtitle", languageCode: "en")
                .localizedCaseInsensitiveContains("Meet Local Fans") == false,
            "landing is not Meet Local Fans"
        )
        expect(
            L10n.t("landing_subtitle", languageCode: "en")
                .localizedCaseInsensitiveContains("Business Owners") == false,
            "landing is not Business Owners"
        )

        expect(
            L10n.t("landing_headline_find_your_game", languageCode: "en") != "landing_headline_find_your_game",
            "headline game not raw key"
        )
        expect(
            L10n.t("landing_sign_in_fan_user", languageCode: "en") != "landing_sign_in_fan_user",
            "fan user not raw key"
        )
        expect(
            !L10n.t("landing_subtitle", languageCode: "en").localizedCaseInsensitiveContains("guest"),
            "subtitle has no guest"
        )
        expect(
            L10n.t("landing_subtitle", languageCode: "en").localizedCaseInsensitiveContains("Explore as a guest") == false,
            "no Explore as a guest"
        )

        expect(BusinessAuthEntryMode.signIn != .choice, "business sign-in is a distinct existing mode")
        expect(BusinessAuthEntryMode.register != .signIn, "business register remains a distinct existing mode")

        if failures == 0 {
            print("[SignedOutLandingTest] ALL PASSED")
        } else {
            print("[SignedOutLandingTest] FAILURES=\(failures)")
            assertionFailure("SignedOutLandingSelfTests failed: \(failures)")
        }
    }
}
#endif
