import Foundation

#if DEBUG
/// DEBUG-only catalog regression audit for known FanGeo localization keys.
///
/// Detects unresolved localization-looking output (`going_play_filter`,
/// `PROFILE_MY_TEAMS_TITLE`) on known presentation keys only — never user content.
enum FanGeoLocalizationRegressionSelfTests {
    private static let snakeKeyRegex = try! NSRegularExpression(
        pattern: "^[a-z0-9]+(?:_[a-z0-9]+)+$"
    )
    private static let upperKeyRegex = try! NSRegularExpression(
        pattern: "^[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+$"
    )

    static let knownPresentationKeys: [String] = [
        "going_play_filter",
        "going_play_upcoming",
        "going_play_badge_pickup",
        "going_play_badge_team",
        "going_pro_upcoming",
        "going_pro_empty_title",
        "going_pro_empty_supporting",
        "going_pro_explore",
        "going_pro_live_alerts_on",
        "going_pro_live_alerts_off",
        "going_pro_live_card_a11y_format",
        "going_pro_live_card_a11y_clock_format",
        "going_pro_live_minute_a11y_format",
        "going_pro_team_alerts_subtitle",
        "pickup_rating_pending_status",
        "fan_teams_relationship_via",
        "action_center_team_event_identity_format",
        "action_center_cta_view_event",
        "fan_teams_filter_all",
        "fan_teams_filter_managing",
        "fan_teams_filter_joined",
        "fan_teams_empty_title",
        "fan_teams_empty_managing_title",
        "fan_teams_empty_joined_title",
        "profile_gender",
        "profile_gender_male",
        "profile_gender_female",
        "profile_gender_non_binary",
        "profile_gender_prefer_not_to_say",
        "profile_my_teams_title",
        "profile_my_teams_subtitle",
        "profile_my_teams_view_all",
        "profile_my_teams_visibility_help",
        "profile_favorite_teams_subtitle",
        "going_tab_title",
        "landing_headline_find_your_game",
        "landing_headline_find_your_people",
        "landing_subtitle",
        "landing_sign_in_chooser_subtitle",
        "landing_sign_in_fan_user",
        "going_watch_chip_im_going",
        "going_watch_chip_a11y_one",
        "going_watch_chip_a11y_other",
        "going_play_filter_all",
        "team_discovery_looking_for_players",
        "team_discovery_looking_for_athletes",
        "team_discovery_looking_for_fans",
        "team_discovery_fan_club_open",
        "discover_team_view_team",
        "discover_team_cluster_a11y_format",
        "discover_place_cluster_a11y_format",
        "discover_mixed_cluster_a11y_format",
        "discover_status_places_and_teams_format",
        "discover_empty_places_or_teams_nearby",
        "discover_pickup_card_format_badge",
        "discover_pickup_emblem_started",
        "discover_pickup_emblem_live",
        "discover_pickup_emblem_full",
        "discover_pickup_emblem_few_spots",
        "discover_pickup_emblem_new",
        "action_center_pickup_invite_title",
        "action_center_pickup_invite_subtitle",
        "action_center_invited_to_team_format",
        "action_center_team_invite_title_one",
        "action_center_team_invite_title_many",
        "action_center_rate_pickup_title",
        "action_center_rate_organizer_title",
        "going_action_needed_rsvp_format",
        "action_center_team_notif_announcement",
        "action_center_team_notif_removed_title",
        "action_center_team_notif_role_title",
        "action_center_wants_to_join_format",
        "action_center_join_decision_title",
        "action_center_badge_new_event_format",
        "action_center_badge_event_type_updated_format",
        "action_center_badge_event_type_cancelled_format",
        "action_center_title_new_event_format",
        "action_center_title_event_updated_format",
        "action_center_title_event_cancelled_format",
        "following_browse_by_country",
        "following_browse_by_league",
        "following_browse_by_team",
        "following_athletes_coming_soon",
        "following_all_athletes",
        "following_top_leagues",
        "following_popular_teams",
        "following_all_teams",
        "following_add_favorite_teams",
        "following_country_counts_format",
        "following_no_teams_in_country",
        "following_picker_title",
        "following_search_teams_leagues_players",
        "following_manage",
        "following_recommended_for_you",
        "following_country_open_hint",
        "following_league_teams_format",
        "following_no_leagues_yet",
        "following_search_teams_in_country_format",
        "following_all_leagues",
        "following_sort_az",
        "following_sort_za",
        "following_filter_sport",
        "following_filter_category",
        "following_category_teams",
        "following_category_national_teams",
        "following_category_featured_athletes",
        "following_category_competitions",
        "following_follow",
        "following_unfollow",
        "following_view_all",
        "following_search_athletes",
        "following_search_national_teams",
        "following_search_competitions",
        "following_search_clear",
        "following_picker_no_results",
        "following_empty_try_filters",
        "following_country_unclassified",
        "following_country_search",
        "favorite_teams",
        "done",
        "security_session_replaced_badge",
        "security_session_replaced_title",
        "security_session_replaced_body",
        "security_session_replaced_device_format",
        "security_session_replaced_signed_out_notice",
        "security_session_replaced_cta",
        "managed_players_edit",
        "managed_players_add_photo",
        "managed_players_change_photo",
        "managed_players_remove_photo",
        "chat_realtime_connecting",
        "chat_realtime_reconnecting",
        "chat_realtime_live",
        "chat_realtime_offline",
        "team_score_who_scored",
        "team_score_skip_scorer",
        "team_score_goal_by",
        "team_score_run_scored_by",
        "team_score_scored_by",
        "team_score_score_by",
        "team_score_scorer",
        "team_score_unknown_scorer",
        "team_score_skip_scorer_a11y",
        "team_score_goal_title_format",
        "team_score_run_title_format",
        "team_score_player_scored_format",
        "team_score_generic_title_format",
        "team_score_team_scored_format",
        "team_score_line",
    ]

    /// Every localization key referenced by the startup / onboarding guide carousel.
    /// Snake-case identifiers only — sentence-as-key English copy is asserted separately.
    static let startupGuideKeys: [String] = [
        "guide_welcome_title",
        "guide_welcome_tagline",
        "guide_welcome_quick_tour",
        "guide_welcome_body",
        "guide_welcome_bullet_1",
        "guide_welcome_bullet_2",
        "guide_welcome_bullet_3",
        "guide_welcome_hero_a11y",
        "discover",
        "guide_discover_primary",
        "guide_discover_bullet_1",
        "guide_discover_bullet_2",
        "guide_discover_bullet_3",
        "guide_discover_hero_a11y",
        "guide_schedule_live_title",
        "guide_schedule_live_primary",
        "guide_schedule_live_bullet_1",
        "guide_schedule_live_bullet_2",
        "guide_schedule_live_bullet_3",
        "guide_schedule_live_bullet_4",
        "guide_schedule_live_hero_a11y",
        "going_tab_title",
        "guide_going_primary",
        "guide_going_body",
        "guide_going_bullet_1",
        "guide_going_bullet_2",
        "guide_going_bullet_3",
        "guide_going_bullet_4",
        "guide_going_bullet_5",
        "guide_going_hero_a11y",
        "guide_going_demo_event_1",
        "guide_going_demo_event_2",
        "guide_going_demo_event_3",
        "guide_going_demo_event_4",
        "guide_going_demo_detail_1",
        "guide_going_demo_detail_2",
        "guide_going_demo_detail_3",
        "guide_going_demo_detail_4",
        "teams",
        "guide_teams_primary",
        "guide_teams_bullet_1",
        "guide_teams_bullet_2",
        "guide_teams_bullet_3",
        "guide_teams_bullet_4",
        "guide_teams_hero_a11y",
        "chat",
        "guide_chat_primary",
        "guide_chat_bullet_1",
        "guide_chat_bullet_2",
        "guide_chat_bullet_3",
        "guide_chat_hero_a11y",
        "profile",
        "guide_profile_primary",
        "guide_profile_bullet_1",
        "guide_profile_bullet_2",
        "guide_profile_bullet_3",
        "guide_profile_callout_reputation",
        "guide_profile_hero_a11y",
        "guide_profile_demo_badge",
        "guide_profile_demo_name",
        "guide_profile_demo_handle",
        "guide_profile_demo_subtitle",
        "guide_profile_demo_xp",
        "guide_profile_demo_teams_metric",
        "guide_profile_demo_primary_team",
        "guide_profile_demo_reputation",
        "guide_profile_demo_trusted_fan",
        "guide_profile_demo_fan_1_name",
        "guide_profile_demo_fan_1_detail",
        "guide_profile_demo_fan_2_name",
        "guide_profile_demo_fan_2_detail",
        "favorite_teams",
        "suggested_fans",
        "rookie_fan",
        "action_center_title",
        "action_center_inbox_group_today",
        "action_center_inbox_group_yesterday",
        "action_center_inbox_group_older",
        "action_center_inbox_group_days_ago_format",
        "action_center_label_when",
        "action_center_label_where",
        "action_center_label_player",
        "action_center_inbox_unread_count_a11y_format",
        "action_center_inbox_total_count_a11y_format",
        "guide_inbox_primary",
        "guide_inbox_bullet_1",
        "guide_inbox_bullet_2",
        "guide_inbox_bullet_3",
        "guide_inbox_bullet_4",
        "guide_inbox_bullet_5",
        "guide_inbox_hero_a11y",
        "guide_inbox_bullets_a11y",
        "guide_inbox_demo_team_invite",
        "guide_inbox_demo_game_invite",
        "guide_inbox_demo_friend",
        "guide_inbox_demo_announcement",
        "guide_inbox_demo_reminder",
        "guide_next",
        "guide_start_exploring",
        "guide_page_of_format",
        "guide_hide_at_startup_hint",
        "guide_close_hint",
        "guide_next_hint",
        "welcome_guide_personalized_greeting_format",
        "team_schedule_date_subtitle",
        "team_schedule_location_subtitle",
    ]

    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[L10nRegressionTest] PASS \(name)")
            } else {
                failures += 1
                print("[L10nRegressionTest] FAIL \(name)")
            }
        }

        let locales = ["en", "es"]
        for lang in locales {
            for key in knownPresentationKeys + startupGuideKeys {
                let value = L10n.t(key, languageCode: lang)
                expect(value != key, "\(lang) \(key) != raw key")
                expect(!value.isEmpty, "\(lang) \(key) non-empty")
                expect(!looksLikeUnresolvedKey(value), "\(lang) \(key) not unresolved-shaped")
                expect(!value.hasPrefix("guide_"), "\(lang) \(key) not leftover guide_ key")
            }
        }

        expect(L10n.t("guide_schedule_live_title", languageCode: "en") == "Schedule & Live", "en Schedule & Live title")
        expect(L10n.t("guide_schedule_live_primary", languageCode: "en") == "Stay On Top of Every Game", "en Schedule & Live primary")
        expect(L10n.t("guide_schedule_live_bullet_1", languageCode: "en") == "Follow live games and scores", "en Schedule bullet 1")
        expect(L10n.t("guide_schedule_live_bullet_2", languageCode: "en") == "Plan watch parties and games", "en Schedule bullet 2")
        expect(L10n.t("guide_schedule_live_bullet_3", languageCode: "en") == "Find pickup and Team events", "en Schedule bullet 3")
        expect(L10n.t("guide_schedule_live_bullet_4", languageCode: "en") == "Follow your favorite pro teams", "en Schedule bullet 4")
        expect(L10n.t("teams", languageCode: "en") == "Teams", "en Teams title")
        expect(L10n.t("guide_teams_primary", languageCode: "en") == "Play Together. Stay Connected.", "en Teams primary")
        expect(L10n.t("guide_teams_bullet_1", languageCode: "en") == "Create or join a team", "en Teams bullet 1")
        expect(L10n.t("guide_teams_bullet_2", languageCode: "en") == "Team Chat, schedule, and roster", "en Teams bullet 2")
        expect(L10n.t("guide_teams_bullet_3", languageCode: "en") == "RSVP and manage game-day plans", "en Teams bullet 3")
        expect(L10n.t("guide_teams_bullet_4", languageCode: "en") == "Add players you manage", "en Teams bullet 4")
        expect(L10n.t("guide_next", languageCode: "en") == "Next", "en Next CTA")
        expect(L10n.t("guide_start_exploring", languageCode: "en") == "Start Exploring", "en Start Exploring CTA")
        expect(L10n.t("guide_profile_demo_badge", languageCode: "en") == "Rookie", "en profile demo badge")
        expect(L10n.t("guide_profile_demo_name", languageCode: "en") == "Alex Morgan", "en profile demo name")

        let pageOf = String(
            format: L10n.t("guide_page_of_format", languageCode: "en"),
            locale: Locale(identifier: "en"),
            Int64(2),
            Int64(8)
        )
        expect(pageOf == "Page 2 of 8", "en page-of interpolation")
        expect(!pageOf.contains("guide_page_of_format"), "en page-of not raw key")

        let greeting = String(
            format: L10n.t("welcome_guide_personalized_greeting_format", languageCode: "en"),
            locale: Locale(identifier: "en"),
            "Alex"
        )
        expect(greeting.contains("Alex"), "en greeting interpolates name")
        expect(!greeting.contains("welcome_guide_personalized_greeting_format"), "en greeting not raw key")

        let hideCheckbox = L10n.t("Don't show this guide at startup", languageCode: "es")
        expect(hideCheckbox != "Don't show this guide at startup", "es hide-at-startup translated")
        expect(!hideCheckbox.hasPrefix("guide_"), "es hide-at-startup not guide_ key")

        expect(L10n.t("going_play_filter", languageCode: "en") == "Filter", "en Filter")
        expect(L10n.t("going_play_upcoming", languageCode: "en") == "Upcoming", "en Upcoming")
        expect(L10n.t("going_play_badge_pickup", languageCode: "en").uppercased().contains("PICKUP"), "en PICKUP badge")
        expect(L10n.t("going_play_badge_team", languageCode: "en").uppercased().contains("TEAM"), "en TEAM badge")
        expect(L10n.t("going_pro_upcoming", languageCode: "en") == "Upcoming Pro Games", "en Upcoming Pro Games")
        expect(L10n.t("going_pro_empty_title", languageCode: "en") == "No pro games yet", "en empty title")
        expect(!L10n.t("going_pro_empty_supporting", languageCode: "en").isEmpty, "en empty supporting")
        expect(L10n.t("going_pro_explore", languageCode: "en") == "Explore Pro Games", "en explore")
        expect(L10n.t("going_pro_live_alerts_on", languageCode: "en") == "Live Alerts ON", "en Live Alerts ON")
        expect(L10n.t("going_pro_live_alerts_off", languageCode: "en") == "Live Alerts OFF", "en Live Alerts OFF")
        expect(L10n.t("going_pro_team_alerts_subtitle", languageCode: "en") == "Kickoff, scores, and final alerts", "en team alerts subtitle")
        expect(L10n.t("pickup_rating_pending_status", languageCode: "en") == "Rating pending", "en rating pending")
        expect(L10n.t("action_center_cta_view_event", languageCode: "en") == "View Event", "en View Event")
        expect(L10n.t("fan_teams_filter_all", languageCode: "en") == "All", "en Teams All")
        expect(L10n.t("fan_teams_filter_managing", languageCode: "en") == "Managing", "en Teams Managing")
        expect(L10n.t("fan_teams_filter_joined", languageCode: "en") == "Joined", "en Teams Joined")
        expect(L10n.t("fan_teams_empty_title", languageCode: "en") == "No teams yet", "en All empty title")
        expect(
            L10n.t("fan_teams_empty_managing_title", languageCode: "en") == "No teams you're managing",
            "en Managing empty title"
        )
        expect(
            L10n.t("fan_teams_empty_joined_title", languageCode: "en") == "No joined teams yet",
            "en Joined empty title"
        )
        for lang in L10n.supportedLanguages.map(\.code) {
            for filter in FanTeamHomeFilter.allCases {
                let key = filter.emptyTitleKey
                let value = L10n.t(key, languageCode: lang)
                expect(value != key, "\(lang) \(key) != raw key")
                expect(!value.isEmpty, "\(lang) \(key) non-empty")
                expect(!looksLikeUnresolvedKey(value), "\(lang) \(key) not unresolved-shaped")
            }
        }

        // Screenshot fixture: All 3 / Managing 3 / Joined 0.
        let joinedEmptyFixture = FanTeamHomeCatalog.build(
            accountTeams: [
                FanTeamSummary(
                    id: UUID(),
                    name: "JT",
                    sport: "soccer",
                    logoURL: nil,
                    logoThumbnailURL: nil,
                    colorHex: nil,
                    competitionLevel: nil,
                    ownerUserId: UUID(),
                    groupConversationId: UUID(),
                    myRole: .owner,
                    memberCount: 4,
                    pendingInvitationCount: 0,
                    pushNotificationsMuted: false,
                    nextGameStartsAt: nil,
                    nextGameTitle: nil,
                    nextGameVenue: nil,
                    createdAt: nil,
                    accessVia: .account,
                    viaManagedPlayerNames: []
                ),
                FanTeamSummary(
                    id: UUID(),
                    name: "IMC Team",
                    sport: "soccer",
                    logoURL: nil,
                    logoThumbnailURL: nil,
                    colorHex: nil,
                    competitionLevel: nil,
                    ownerUserId: UUID(),
                    groupConversationId: UUID(),
                    myRole: .manager,
                    memberCount: 4,
                    pendingInvitationCount: 0,
                    pushNotificationsMuted: false,
                    nextGameStartsAt: nil,
                    nextGameTitle: nil,
                    nextGameVenue: nil,
                    createdAt: nil,
                    accessVia: .account,
                    viaManagedPlayerNames: []
                ),
                FanTeamSummary(
                    id: UUID(),
                    name: "ER basketball",
                    sport: "basketball",
                    logoURL: nil,
                    logoThumbnailURL: nil,
                    colorHex: nil,
                    competitionLevel: nil,
                    ownerUserId: UUID(),
                    groupConversationId: UUID(),
                    myRole: .owner,
                    memberCount: 4,
                    pendingInvitationCount: 0,
                    pushNotificationsMuted: false,
                    nextGameStartsAt: nil,
                    nextGameTitle: nil,
                    nextGameVenue: nil,
                    createdAt: nil,
                    accessVia: .account,
                    viaManagedPlayerNames: []
                )
            ],
            guardianOnlyTeams: [],
            viaNamesByTeamId: [:]
        )
        let joinedEmptyCounts = FanTeamHomeCatalog.counts(for: joinedEmptyFixture)
        expect(joinedEmptyCounts.all == 3, "fixture All count is 3")
        expect(joinedEmptyCounts.managing == 3, "fixture Managing count is 3")
        expect(joinedEmptyCounts.joined == 0, "fixture Joined count is 0")
        expect(
            FanTeamHomeCatalog.displayItems(
                from: joinedEmptyFixture,
                filter: .joined,
                searchText: ""
            ).isEmpty,
            "Joined 0 shows no Team cards"
        )
        let joinedEmptyTitle = L10n.t(FanTeamHomeFilter.joined.emptyTitleKey, languageCode: "en")
        expect(joinedEmptyTitle == "No joined teams yet", "Joined empty title is localized")
        expect(
            joinedEmptyTitle != "fan_teams_empty_joined_title",
            "raw fan_teams_empty_joined_title never appears"
        )
        expect(
            FanTeamHomeCatalog.displayItems(
                from: joinedEmptyFixture,
                filter: .all,
                searchText: ""
            ).count == 3,
            "switching to All restores 3 Teams"
        )
        expect(
            FanTeamHomeCatalog.displayItems(
                from: joinedEmptyFixture,
                filter: .managing,
                searchText: ""
            ).count == 3,
            "switching to Managing restores 3 managed Teams"
        )
        expect(L10n.t("profile_my_teams_title", languageCode: "en") == "My Teams", "en My Teams")
        expect(L10n.t("profile_my_teams_subtitle", languageCode: "en") == "Teams I'm part of", "en profile subtitle")
        expect(L10n.t("profile_my_teams_view_all", languageCode: "en") == "View All", "en View All")
        expect(L10n.t("profile_favorite_teams_subtitle", languageCode: "en") == "Professional clubs you follow.", "en favorite teams subtitle")
        expect(L10n.t("going_tab_title", languageCode: "en") == "My Sports", "en My Sports tab")
        expect(L10n.t("going_watch_chip_im_going", languageCode: "en") == "I'm Going", "en Watch chip I'm Going")
        expect(L10n.t("chat_realtime_live", languageCode: "en") == "Live", "en Live")
        expect(L10n.t("chat_realtime_connecting", languageCode: "en") == "Connecting…", "en Connecting")
        expect(L10n.t("chat_realtime_reconnecting", languageCode: "en") == "Reconnecting…", "en Reconnecting")
        expect(L10n.t("chat_realtime_offline", languageCode: "en") == "Offline", "en Offline")
        expect(
            ChatRealtimeConnectionPresentation.chrome(
                status: .connecting,
                statusEnteredAt: Date().addingTimeInterval(-1),
                now: Date(),
                threadContentReady: true
            ) == nil,
            "cached chat hides Connecting…"
        )
        expect(
            ChatRealtimeConnectionPresentation.sendRequiresRealtimeSubscription == false,
            "send does not require realtime subscribe"
        )
        expect(L10n.t("landing_headline_find_your_game", languageCode: "en") == "Find your game.", "en landing headline game")
        expect(L10n.t("landing_sign_in_fan_user", languageCode: "en") == "FanGeo User", "en FanGeo User")
        expect(L10n.t("managed_players_edit", languageCode: "en") == "Edit Player", "en Edit Player")
        expect(L10n.t("managed_players_add_photo", languageCode: "en") == "Add Photo", "en Add Photo")
        expect(
            !L10n.t("managed_players_edit", languageCode: "en").contains("%@")
                && !L10n.t("managed_players_edit", languageCode: "en").contains("%d"),
            "en Edit Player has no format tokens"
        )
        expect(
            !L10n.t("managed_players_add_photo", languageCode: "en").contains("%@")
                && !L10n.t("managed_players_add_photo", languageCode: "en").contains("%d"),
            "en Add Photo has no format tokens"
        )
        for lang in L10n.supportedLanguages.map(\.code) {
            for key in ["managed_players_edit", "managed_players_add_photo"] {
                let value = L10n.t(key, languageCode: lang)
                expect(value != key, "\(lang) \(key) != raw key")
                expect(!value.isEmpty, "\(lang) \(key) non-empty")
                expect(!looksLikeUnresolvedKey(value), "\(lang) \(key) not unresolved-shaped")
                expect(!value.contains("%@") && !value.contains("%d"), "\(lang) \(key) no format mismatch")
            }
        }

        let via = String(
            format: L10n.t("fan_teams_relationship_via", languageCode: "en"),
            locale: Locale(identifier: "en"),
            "Emma"
        )
        expect(via == "Via Emma", "en Via interpolation")
        expect(!via.contains("fan_teams_relationship_via"), "en Via not raw key")

        let identity = String(
            format: L10n.t("action_center_team_event_identity_format", languageCode: "en"),
            locale: Locale(identifier: "en"),
            "IMC Team",
            "Practice"
        )
        expect(identity == "IMC Team · Practice", "en identity interpolation")
        expect(!identity.contains("action_center_team_event_identity_format"), "en identity not raw key")

        let viaES = String(
            format: L10n.t("fan_teams_relationship_via", languageCode: "es"),
            locale: Locale(identifier: "es"),
            "Emma"
        )
        expect(viaES.contains("Emma"), "es Via interpolates name")
        expect(viaES != "fan_teams_relationship_via", "es Via != key")
        expect(L10n.t("fan_teams_filter_all", languageCode: "es") == "Todos", "es All")
        expect(L10n.t("going_play_filter", languageCode: "es") == "Filtro", "es Filter")

        let titled = L10n.t("profile_my_teams_title", languageCode: "en")
        expect(titled.uppercased() == "MY TEAMS", "uppercase presentation is MY TEAMS")
        expect(titled.uppercased() != "PROFILE_MY_TEAMS_TITLE", "not uppercase raw key")
        expect(
            L10n.t("PROFILE_MY_TEAMS_TITLE", languageCode: "en") == "PROFILE_MY_TEAMS_TITLE",
            "legacy uppercase key is not a catalog duplicate"
        )

        let followingVisibleKeys = [
            "following_search_teams_leagues_players",
            "following_manage",
            "following_recommended_for_you",
        ]
        expect(
            L10n.t("following_search_teams_leagues_players")
                != "following_search_teams_leagues_players",
            "default-locale L10n.t search != raw key"
        )
        expect(L10n.t("following_manage") != "following_manage", "default-locale L10n.t manage != raw key")
        expect(
            L10n.t("following_recommended_for_you") != "following_recommended_for_you",
            "default-locale L10n.t recommended != raw key"
        )
        expect(
            L10n.t("following_search_teams_leagues_players", languageCode: "en")
                == "Search teams, leagues, players",
            "en Following search placeholder"
        )
        expect(L10n.t("following_manage", languageCode: "en") == "Manage", "en Following Manage")
        expect(
            L10n.t("following_recommended_for_you", languageCode: "en") == "Recommended for You",
            "en Recommended for You"
        )
        expect(
            FollowingPresentationCopy.searchPlaceholder(categoryTitle: "Teams", languageCode: "en")
                == "Search teams, leagues, players",
            "en Following search placeholder via presentation copy"
        )
        expect(FollowingPresentationCopy.manage(languageCode: "en") == "Manage", "en Following Manage copy")
        expect(
            FollowingPresentationCopy.recommendedForYou(languageCode: "en") == "Recommended for You",
            "en Recommended for You copy"
        )
        let leagueTeams = String(
            format: L10n.t("following_league_teams_format", languageCode: "en"),
            locale: Locale(identifier: "en"),
            12
        )
        expect(leagueTeams == "12 teams", "en league teams interpolation")
        expect(!leagueTeams.contains("following_league_teams_format"), "en league teams not raw key")
        let searchInCountry = String(
            format: L10n.t("following_search_teams_in_country_format", languageCode: "en"),
            locale: Locale(identifier: "en"),
            "France"
        )
        expect(searchInCountry == "Search teams in France", "en country search interpolation")
        expect(
            !searchInCountry.contains("following_search_teams_in_country_format"),
            "en country search not raw key"
        )

        for lang in L10n.supportedLanguages.map(\.code) {
            for key in followingVisibleKeys + [
                "following_country_open_hint",
                "following_league_teams_format",
                "following_no_leagues_yet",
                "following_search_teams_in_country_format",
                "following_all_leagues",
                "following_sort_az",
                "following_sort_za",
            ] {
                let value = L10n.t(key, languageCode: lang)
                expect(value != key, "\(lang) \(key) != raw key")
                expect(!value.isEmpty, "\(lang) \(key) non-empty")
                expect(!looksLikeUnresolvedKey(value), "\(lang) \(key) not unresolved-shaped")
            }
            let leagueFormat = L10n.t("following_league_teams_format", languageCode: lang)
            expect(leagueFormat.contains("%d") || leagueFormat.contains("%lld"), "\(lang) league format has %d")
            let countrySearchFormat = L10n.t("following_search_teams_in_country_format", languageCode: lang)
            expect(countrySearchFormat.contains("%@"), "\(lang) country search format has %@")
        }

        expect(
            L10n.t("team_schedule_date_subtitle", languageCode: "en") == "Choose the date for this event.",
            "en Create Game date subtitle"
        )
        expect(
            L10n.t("team_schedule_location_subtitle", languageCode: "en") == "Choose where this event will take place.",
            "en Create Game location subtitle"
        )

        if failures == 0 {
            print("[L10nRegressionTest] ALL PASSED")
        } else {
            print("[L10nRegressionTest] FAILURES=\(failures)")
            assertionFailure("FanGeoLocalizationRegressionSelfTests failed: \(failures)")
        }
    }

    static func looksLikeUnresolvedKey(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if snakeKeyRegex.firstMatch(in: trimmed, range: range) != nil { return true }
        if upperKeyRegex.firstMatch(in: trimmed, range: range) != nil { return true }
        return false
    }
}
#endif
