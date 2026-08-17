import Foundation

#if DEBUG
/// Screenshot-shaped Following chrome audit. Localization only — does not change
/// favorite ordering or recommendation contents.
enum FollowingPresentationSelfTests {
    /// Screenshot fixture: Mbappe, France, Inter Milan, Paris Saint-Germain.
    static let screenshotFavoriteIDs = [
        "player-kylian-mbappe",
        "soccer-france",
        "soccer-inter",
        "soccer-psg",
    ]

    static let screenshotRawKeys = [
        "following_search_teams_leagues_players",
        "following_manage",
        "following_recommended_for_you",
    ]

    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[FollowingPresentationTest] PASS \(name)")
            } else {
                failures += 1
                print("[FollowingPresentationTest] FAIL \(name)")
            }
        }

        let chrome = screenshotChrome(languageCode: "en")
        expect(chrome.header == "Following", "header Following")
        expect(chrome.done == "Done", "Done")
        expect(
            chrome.searchPlaceholder
                == FollowingPresentationCopy.searchPlaceholder(categoryTitle: "Teams", languageCode: "en"),
            "search uses FollowingPresentationCopy"
        )
        expect(chrome.searchPlaceholder == "Search teams, leagues, players", "search placeholder")
        expect(chrome.sport == "Sport", "Sport")
        expect(chrome.category == "Category", "Category")
        expect(chrome.teams == "Teams", "Teams")
        expect(chrome.nationalTeams == "National Teams", "National Teams")
        expect(chrome.featuredAthletes == "Featured Athletes", "Featured Athletes")
        expect(chrome.favoriteTeams == "Favorite Teams", "Favorite Teams")
        expect(chrome.manage == FollowingPresentationCopy.manage(languageCode: "en"), "manage uses FollowingPresentationCopy")
        expect(chrome.manage == "Manage", "Manage")
        expect(chrome.browseByCountry == "Browse by Country", "Browse by Country")
        expect(chrome.viewAll == "View all", "View all")
        expect(
            chrome.recommended == FollowingPresentationCopy.recommendedForYou(languageCode: "en"),
            "recommended uses FollowingPresentationCopy"
        )
        expect(chrome.recommended == "Recommended for You", "Recommended for You")
        expect(chrome.browseByLeague == "Browse by League", "Browse by League")
        expect(chrome.browseByTeam == "Browse by Team", "Browse by Team")

        expect(
            L10n.t(FollowingPresentationCopy.searchTeamsLeaguesPlayersKey)
                != FollowingPresentationCopy.searchTeamsLeaguesPlayersKey,
            "runtime L10n.t search != raw key"
        )
        expect(
            L10n.t(FollowingPresentationCopy.manageKey) != FollowingPresentationCopy.manageKey,
            "runtime L10n.t manage != raw key"
        )
        expect(
            L10n.t(FollowingPresentationCopy.recommendedForYouKey)
                != FollowingPresentationCopy.recommendedForYouKey,
            "runtime L10n.t recommended != raw key"
        )

        for raw in screenshotRawKeys {
            expect(!chrome.allVisibleStrings.contains(raw), "raw \(raw) never appears")
            expect(
                chrome.allVisibleStrings.allSatisfy { $0 != raw },
                "chrome values are not \(raw)"
            )
        }

        for lang in L10n.supportedLanguages.map(\.code) {
            let localized = screenshotChrome(languageCode: lang)
            for value in localized.allVisibleStrings {
                expect(!value.isEmpty, "\(lang) chrome non-empty")
                expect(
                    FanGeoLocalizationRegressionSelfTests.looksLikeUnresolvedKey(value) == false,
                    "\(lang) chrome not unresolved-shaped \(value)"
                )
            }
            for raw in screenshotRawKeys {
                expect(!localized.allVisibleStrings.contains(raw), "\(lang) never shows \(raw)")
            }
        }

        for id in screenshotFavoriteIDs {
            expect(FavoriteTeamCatalog.team(id: id) != nil, "catalog contains \(id)")
        }

        let resolved = FavoriteTeamsStore.resolvedTeams(fromIDs: screenshotFavoriteIDs)
        expect(resolved.map(\.id) == screenshotFavoriteIDs, "screenshot favorite order")
        expect(
            FavoriteTeamsStore.decodeIDs(from: FavoriteTeamsStore.encodeIDs(screenshotFavoriteIDs))
                == screenshotFavoriteIDs,
            "CSV round-trip preserves screenshot order"
        )

        let soccerVisible = FavoriteFollowingCountryBrowse.uniquedTeams(
            resolved.filter { $0.sport == .soccer }
        )
        expect(
            soccerVisible.map(\.id) == screenshotFavoriteIDs,
            "soccer sport filter does not reshuffle screenshot favorites"
        )

        let teamsCategory = FavoriteTeamCatalog.defaultCategoryID(for: .soccer)
        let baseTeams = FavoriteTeamCatalog.teams(sport: .soccer, categoryID: teamsCategory)
        let recommendedA = FavoriteFollowingCountryBrowse.recommendedTeams(
            from: baseTeams,
            excludingIDs: Set(screenshotFavoriteIDs)
        )
        let recommendedB = FavoriteFollowingCountryBrowse.recommendedTeams(
            from: baseTeams,
            excludingIDs: Set(screenshotFavoriteIDs)
        )
        expect(
            recommendedA.map(\.id) == recommendedB.map(\.id),
            "recommendation order is independent of localization"
        )
        expect(
            recommendedA.allSatisfy { !screenshotFavoriteIDs.contains($0.id) },
            "recommended cards exclude followed IDs"
        )

        if failures == 0 {
            print("[FollowingPresentationTest] ALL PASSED")
        } else {
            print("[FollowingPresentationTest] FAILURES=\(failures)")
            assertionFailure("FollowingPresentationSelfTests failed: \(failures)")
        }
    }

    private struct Chrome {
        let header: String
        let done: String
        let searchPlaceholder: String
        let sport: String
        let category: String
        let teams: String
        let nationalTeams: String
        let featuredAthletes: String
        let favoriteTeams: String
        let manage: String
        let browseByCountry: String
        let viewAll: String
        let recommended: String
        let browseByLeague: String
        let browseByTeam: String

        var allVisibleStrings: [String] {
            [
                header,
                done,
                searchPlaceholder,
                sport,
                category,
                teams,
                nationalTeams,
                featuredAthletes,
                favoriteTeams,
                manage,
                browseByCountry,
                viewAll,
                recommended,
                browseByLeague,
                browseByTeam,
            ]
        }
    }

    private static func screenshotChrome(languageCode: String) -> Chrome {
        Chrome(
            header: L10n.t("following_picker_title", languageCode: languageCode),
            done: L10n.t("done", languageCode: languageCode),
            searchPlaceholder: FollowingPresentationCopy.searchPlaceholder(
                categoryTitle: "Teams",
                languageCode: languageCode
            ),
            sport: L10n.t("following_filter_sport", languageCode: languageCode),
            category: L10n.t("following_filter_category", languageCode: languageCode),
            teams: L10n.t("following_category_teams", languageCode: languageCode),
            nationalTeams: L10n.t("following_category_national_teams", languageCode: languageCode),
            featuredAthletes: L10n.t("following_category_featured_athletes", languageCode: languageCode),
            favoriteTeams: L10n.t("favorite_teams", languageCode: languageCode),
            manage: FollowingPresentationCopy.manage(languageCode: languageCode),
            browseByCountry: L10n.t("following_browse_by_country", languageCode: languageCode),
            viewAll: L10n.t("following_view_all", languageCode: languageCode),
            recommended: FollowingPresentationCopy.recommendedForYou(languageCode: languageCode),
            browseByLeague: L10n.t("following_browse_by_league", languageCode: languageCode),
            browseByTeam: L10n.t("following_browse_by_team", languageCode: languageCode)
        )
    }
}
#endif
