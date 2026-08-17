import Foundation

/// Presentation strings for the Following picker (`FavoriteTeamsPickerSheet`).
/// Views and DEBUG tests must use this so they share the same `L10n.t` path.
nonisolated enum FollowingPresentationCopy {
    static let searchTeamsLeaguesPlayersKey = "following_search_teams_leagues_players"
    static let manageKey = "following_manage"
    static let recommendedForYouKey = "following_recommended_for_you"

    static func searchPlaceholder(categoryTitle: String, languageCode: String) -> String {
        switch categoryTitle {
        case "National Teams":
            return L10n.t("following_search_national_teams", languageCode: languageCode)
        case "Featured Athletes", "Fighters", "Drivers":
            return L10n.t("following_search_athletes", languageCode: languageCode)
        case "Competitions & Tournaments":
            return L10n.t("following_search_competitions", languageCode: languageCode)
        default:
            return L10n.t(searchTeamsLeaguesPlayersKey, languageCode: languageCode)
        }
    }

    static func manage(languageCode: String) -> String {
        L10n.t(manageKey, languageCode: languageCode)
    }

    static func recommendedForYou(languageCode: String) -> String {
        L10n.t(recommendedForYouKey, languageCode: languageCode)
    }

#if DEBUG
    static func logResolvedKeys(languageCode: String, categoryTitle: String) {
        let pairs: [(String, String)] = [
            (searchTeamsLeaguesPlayersKey, searchPlaceholder(categoryTitle: categoryTitle, languageCode: languageCode)),
            (manageKey, manage(languageCode: languageCode)),
            (recommendedForYouKey, recommendedForYou(languageCode: languageCode)),
        ]
        for (key, value) in pairs {
            if value == key {
                print("[LocalizationDebug] missingKey=\(key) locale=\(languageCode)")
            } else {
                print("[LocalizationDebug] key=\(key) resolved=\(value) locale=\(languageCode)")
            }
        }
    }
#endif
}
