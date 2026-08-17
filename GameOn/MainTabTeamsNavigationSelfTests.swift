import Foundation

#if DEBUG
enum MainTabTeamsNavigationSelfTests {
    static func runAll() {
        // Floating bar destinations (6): Discover | Schedule | Going | Teams | Chat | Profile.
        // AppTab.live remaps into Schedule → Live. AppTab.following is the Going root tab.
        let barOrder = ["discover", "calendar", "following", "teams", "chat", "account"]
        let allCases = MainTabView.AppTab.allCases.map(\.rawValue)
        assert(allCases.contains("teams"), "AppTab.teams must exist")
        assert(allCases.contains("calendar"), "AppTab.calendar is Schedule")
        assert(allCases.contains("live"), "AppTab.live alias retained for deep links")
        assert(allCases.contains("following"), "AppTab.following is Going root tab")
        assert(allCases.contains("chat"), "AppTab.chat retained")
        for raw in barOrder {
            assert(MainTabView.AppTab(rawValue: raw) != nil, "bar tab \(raw) must decode")
        }
        assert(MainTabView.AppTab(rawValue: "live") == .live)
        assert(MainTabView.AppTab(rawValue: "following") == .following)
        assert(MainTabView.AppTab(rawValue: "not_a_tab") == nil)

        var sawTeams = false
        FanGeoAnnouncementCTAAction.perform("teams") { outcome in
            if case .navigateToTab(let raw) = outcome, raw == "teams" {
                sawTeams = true
            }
        }
        assert(sawTeams, "announcement cta teams → AppTab.teams")

        var sawGoing = false
        FanGeoAnnouncementCTAAction.perform("going") { outcome in
            if case .navigateToTab(let raw) = outcome, raw == "following" {
                sawGoing = true
            }
        }
        assert(sawGoing, "announcement cta going → following (Going root tab)")

        var sawLive = false
        FanGeoAnnouncementCTAAction.perform("live") { outcome in
            if case .navigateToTab(let raw) = outcome, raw == "live" {
                sawLive = true
            }
        }
        assert(sawLive, "announcement cta live → live (Schedule Live alias)")

        // Schedule hub surfaces — Going is not a Schedule surface.
        assert(ScheduleHubSurface.primarySegments == [.live, .watch, .play, .pro])
        assert(ScheduleHubSurface.allCases == [.live, .watch, .play, .pro])
        assert(ScheduleHubSurface.from(calendarFilter: .venueGames) == .watch)
        assert(ScheduleHubSurface.from(calendarFilter: .pickupGames) == .play)
        assert(ScheduleHubSurface.from(calendarFilter: .proGames) == .pro)
        assert(ScheduleHubSurface.live.calendarFilter == nil)
        assert(ScheduleHubSurface.migrating(rawValue: "going") == .watch)
        assert(ScheduleHubSurface.migrating(rawValue: "live") == .live)
        assert(ScheduleHubSurface.legacyGoingRawValue == "going")
        assert(!ScheduleHubSurface.allCases.map(\.rawValue).contains("going"))

        print("[MainTabTeamsNavigationSelfTests] PASS")
    }
}
#endif
