import Foundation

#if DEBUG
enum GoingPlaySelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[GoingPlayTest] PASS \(name)")
            } else {
                failures += 1
                print("[GoingPlayTest] FAIL \(name)")
            }
        }

        let lang = "en"
        let now = Date()
        let pickupId = UUID()
        let practiceId = UUID()
        let scrimmageId = UUID()
        let leagueId = UUID()
        let tournamentId = UUID()
        let rideId = UUID()
        let meetingId = UUID()
        let announcementId = UUID()
        let teamId = UUID()
        let creatorId = UUID()

        func identity(
            gameId: UUID,
            name: String,
            sport: String,
            logo: String? = nil
        ) -> PickupDiscoverTeamIdentity {
            PickupDiscoverTeamIdentity(
                pickupGameId: gameId,
                teamId: teamId,
                teamName: name,
                teamSport: sport,
                colorHex: "#7B61F2",
                logoURL: logo,
                logoThumbnailURL: logo,
                displayRefreshToken: nil
            )
        }

        func card(
            gameId: UUID,
            title: String,
            sport: String,
            start: Date,
            pill: PickupFollowingJoinRequestPillKind = .approved
        ) -> PickupGameJoinRequestCardDisplay {
            PickupGameJoinRequestCardDisplay(
                id: UUID(),
                pickupGameId: gameId,
                title: title,
                sport: sport,
                game_start_at: ISO8601DateFormatter().string(from: start),
                dateTimeLine: "Aug 10, 2026 • 6:57 PM – 8:57 PM",
                locationLine: "Jordan River • Riverton, UT",
                organizerUserId: creatorId,
                organizerName: "FanGeo Demo User",
                pill: pill,
                spotsRemainingSummary: "0 spots open"
            )
        }

        func row(
            id: UUID,
            title: String,
            sport: String,
            format: String,
            start: Date,
            opponent: String? = nil,
            subtype: String? = nil
        ) -> PickupGameRow {
            let startRaw = ISO8601DateFormatter().string(from: start)
            return PickupGameRow(
                id: id,
                creator_user_id: creatorId,
                creator_email: nil,
                title: title,
                sport: sport,
                sport_subtype: subtype,
                description: nil,
                game_format: format,
                skill_level: "casual",
                game_start_at: startRaw,
                end_time: ISO8601DateFormatter().string(from: start.addingTimeInterval(7200)),
                address: "South Towne Field",
                city: "Sandy",
                state: "UT",
                latitude: 40.5,
                longitude: -111.8,
                is_visible: true,
                players_needed: 10,
                play_environment: "outdoor",
                participant_preference: "anyone",
                age_min: nil,
                age_max: nil,
                is_free: true,
                entry_fee_amount: nil,
                max_players: 22,
                status: "active",
                approved_join_count: 4,
                cleanup_delay_hours: 12,
                remove_after_at: nil,
                created_at: startRaw,
                updated_at: startRaw,
                opponent_name: opponent
            )
        }

        expect(GoingPlayProjection.isPlayableTeamEvent(GameType.practice), "1/3 practice playable")
        expect(GoingPlayProjection.isPlayableTeamEvent(GameType.scrimmage), "3 scrimmage playable")
        expect(GoingPlayProjection.isPlayableTeamEvent(GameType.league_game), "4 league playable")
        expect(GoingPlayProjection.isPlayableTeamEvent(GameType.tournament_game), "5 tournament playable")
        expect(GoingPlayProjection.isPlayableTeamEvent(GameType.clinic), "6 group/clinic playable")
        expect(GoingPlayProjection.isPlayableTeamEvent(GameType.other), "other playable")
        expect(!GoingPlayProjection.isPlayableTeamEvent(GameType.team_meeting), "10 meeting excluded")
        expect(!GoingPlayProjection.isPlayableTeamEvent(GameType.announcement), "11 announcement excluded")
        expect(GoingPlayProjection.isPlayableTeamEvent(FanTeamGameType.practice), "practice FanTeamGameType")

        let pickupStart = now.addingTimeInterval(3600)
        let practiceStart = now.addingTimeInterval(7200)
        let leagueStart = now.addingTimeInterval(10_800)
        let rideStart = now.addingTimeInterval(14_400)
        let meetingStart = now.addingTimeInterval(18_000)

        let pickupCard = card(gameId: pickupId, title: "Rock Climbing Demo", sport: "Climbing", start: pickupStart)
        let practiceCard = card(gameId: practiceId, title: "IMC Team Practice", sport: "Badminton", start: practiceStart)
        let meetingCard = card(gameId: meetingId, title: "Staff Meeting", sport: "Soccer", start: meetingStart)

        let games: [UUID: PickupGameRow] = [
            pickupId: row(id: pickupId, title: "Rock Climbing Demo", sport: "Climbing", format: "pickup", start: pickupStart),
            practiceId: row(id: practiceId, title: "IMC Team Practice", sport: "Badminton", format: "practice", start: practiceStart),
            leagueId: row(
                id: leagueId,
                title: "League",
                sport: "Soccer",
                format: "league_game",
                start: leagueStart,
                opponent: "Brighton FC"
            ),
            tournamentId: row(id: tournamentId, title: "Cup Tie", sport: "Soccer", format: "tournament_game", start: now.addingTimeInterval(12_000)),
            rideId: row(
                id: rideId,
                title: "Wasatch MTB Ride",
                sport: "Cycling",
                format: "clinic",
                start: rideStart,
                subtype: "mountain_biking"
            ),
            meetingId: row(id: meetingId, title: "Staff Meeting", sport: "Soccer", format: "team_meeting", start: meetingStart),
            announcementId: row(id: announcementId, title: "Team Notice", sport: "Soccer", format: "announcement", start: now.addingTimeInterval(20_000)),
            scrimmageId: row(id: scrimmageId, title: "Scrimmage", sport: "Soccer", format: "scrimmage", start: now.addingTimeInterval(8000))
        ]

        let identities: [UUID: PickupDiscoverTeamIdentity] = [
            practiceId: identity(gameId: practiceId, name: "IMC Team", sport: "Badminton", logo: "https://example.com/logo.png"),
            leagueId: identity(gameId: leagueId, name: "JT FC", sport: "Soccer"),
            tournamentId: identity(gameId: tournamentId, name: "JT FC", sport: "Soccer"),
            rideId: identity(gameId: rideId, name: "Wasatch MTB", sport: "Cycling"),
            meetingId: identity(gameId: meetingId, name: "IMC Team", sport: "Soccer"),
            announcementId: identity(gameId: announcementId, name: "IMC Team", sport: "Soccer"),
            scrimmageId: identity(gameId: scrimmageId, name: "IMC Team", sport: "Soccer")
        ]

        let playing = GoingPlayProjection.playingItems(
            pickupCards: [pickupCard, practiceCard, meetingCard],
            resolvedGame: { games[$0] },
            teamIdentities: identities,
            teamParticipations: [],
            hostedGameIds: [],
            languageCode: lang,
            now: now
        )
        expect(playing.contains(where: { $0.pickupGameId == pickupId && $0.source == .pickup }), "1 pickup playing renders")
        expect(playing.contains(where: { $0.pickupGameId == practiceId && $0.source == .team }), "2 team practice playing")
        expect(!playing.contains(where: { $0.pickupGameId == meetingId }), "10 meeting excluded from playing")
        expect(playing.filter { $0.pickupGameId == practiceId }.count == 1, "36 no duplicate practice")

        let leagueTitle = GoingPlayProjection.teamEventTitle(
            customTitle: nil,
            teamName: "JT FC",
            opponentName: "Brighton FC",
            format: .league_game,
            sport: "Soccer",
            languageCode: lang
        )
        expect(leagueTitle.contains("JT FC"), "4 matchup includes home")
        expect(leagueTitle.lowercased().contains("brighton"), "4 matchup includes opponent")
        expect(!leagueTitle.contains(leagueId.uuidString), "4 no UUID in title")

        let rideTitle = GoingPlayProjection.teamEventTitle(
            customTitle: "Wasatch MTB Ride",
            teamName: "Wasatch MTB",
            opponentName: nil,
            format: .clinic,
            sport: "Cycling",
            languageCode: lang
        )
        expect(rideTitle == "Wasatch MTB Ride", "6 custom group-ride title")

        let cyclingIdentity = SportSubtypeCatalog.identityLine(
            sport: "Cycling",
            subtype: "mountain_biking",
            languageCode: lang
        )
        expect(!cyclingIdentity.isEmpty, "7 cycling subtype remains labeled")

        let scooterFamily = SportSubtypeCatalog.family(forSport: "Electric Scooter")
        expect(scooterFamily != nil, "8 electric scooter family exists")
        let inlineFamily = SportSubtypeCatalog.family(forSport: "Inline Skating")
        expect(inlineFamily != nil, "9 inline skating family exists")

        let tournamentLabel = GoingPlayProjection.eventTypeLabel(
            format: .tournament_game,
            sport: "Soccer",
            languageCode: lang
        )
        expect(!tournamentLabel.isEmpty, "5 tournament label")

        let hostedPickup = row(id: pickupId, title: "Hosted Pickup", sport: "Soccer", format: "pickup", start: pickupStart)
        let hostedTeam = row(id: practiceId, title: "Hosted Practice", sport: "Badminton", format: "practice", start: practiceStart)
        let hostedMeeting = row(id: meetingId, title: "Hosted Meeting", sport: "Soccer", format: "team_meeting", start: meetingStart)
        let hosting = GoingPlayProjection.hostingItems(
            hostedRows: [hostedPickup, hostedTeam, hostedMeeting],
            teamIdentities: identities,
            languageCode: lang,
            now: now
        )
        expect(hosting.contains(where: { $0.pickupGameId == pickupId && $0.source == .pickup }), "12 pickup hosting unchanged")
        expect(hosting.contains(where: { $0.pickupGameId == practiceId && $0.source == .team }), "13 team hosting is created event")
        expect(!hosting.contains(where: { $0.pickupGameId == meetingId }), "13 meeting not in hosting")
        expect(hosting.count == 2, "18 hosting count == rendered projection count")

        expect(GoingPlayProjection.compactCountBadge(playing.count) == (playing.count > 9 ? "9+" : "\(playing.count)"), "17 playing count badge")

        let managed = GoingPlayTeamParticipation(
            pickupGameId: leagueId,
            teamId: teamId,
            teamName: "JT FC",
            teamSport: "Soccer",
            sportSubtype: nil,
            colorHex: nil,
            logoURL: nil,
            logoThumbnailURL: nil,
            eventType: .league_game,
            customTitle: nil,
            opponentName: "Brighton FC",
            startsAt: leagueStart,
            endsAt: leagueStart.addingTimeInterval(7200),
            locationLine: "South Towne Field · Sandy, UT",
            createdBy: UUID(),
            viaManagedPlayerNames: ["Emma"],
            isCreator: false
        )
        let playingWithManaged = GoingPlayProjection.playingItems(
            pickupCards: [pickupCard],
            resolvedGame: { games[$0] },
            teamIdentities: identities,
            teamParticipations: [managed],
            hostedGameIds: [],
            languageCode: lang,
            now: now
        )
        expect(
            playingWithManaged.contains(where: { $0.pickupGameId == leagueId && $0.viaManagedPlayerNames.contains("Emma") }),
            "16 managed-player Team participation"
        )

        let mixed = GoingPlayProjection.playingItems(
            pickupCards: [practiceCard, pickupCard],
            resolvedGame: { games[$0] },
            teamIdentities: identities,
            teamParticipations: [managed],
            hostedGameIds: [],
            languageCode: lang,
            now: now
        )
        let starts = mixed.map(\.startAt)
        expect(starts == starts.sorted(), "20 mixed chronological sort")

        expect(identities[practiceId]?.hasCustomLogo == true, "21 team logo present")
        expect(identities[leagueId]?.hasCustomLogo == false, "22 team logo fallback")

        let dest = PendingTeamScheduleEventDeepLink(teamId: teamId, pickupGameId: practiceId)
        expect(dest.teamId == teamId && dest.pickupGameId == practiceId, "24 View Event uses team_id + pickup_game_id")

        expect(GoingPlayProjection.participation(from: .approved) == .approved, "25 approved lifecycle")
        expect(GoingPlayProjection.teamPlayingParticipation(pill: .approved) == .approved, "14 team approved state")
        expect(GoingPlayProjection.teamPlayingParticipation(pill: nil) == .going, "14 managed going state")
        expect(GoingPlayProjection.participation(from: .pending) == .pending, "pending unchanged")

        expect(GoingPlayFilter.all == GoingPlayFilter.all, "1 play defaults conceptually to All")
        expect(GoingPlayFilter.allCases == [.all, .hosting, .invites, .pickups, .teamEvents], "filter cases")

        let unified = GoingPlayProjection.unifiedItems(
            playing: playing,
            hosting: hosting,
            invites: [],
            now: now
        )
        expect(unified.filter { $0.pickupGameId == pickupId }.count == 1, "12 no duplicate pickup in All")
        expect(unified.contains(where: { $0.pickupGameId == pickupId && $0.source == .pickup }), "pickup in unified")
        expect(unified.contains(where: { $0.pickupGameId == practiceId && $0.source == .team }), "practice in unified")
        let unifiedStarts = unified.map(\.startAt)
        expect(unifiedStarts == unifiedStarts.sorted(), "11 unified chronological sort")

        let counts = GoingPlayProjection.filterCounts(unified: unified, hosting: hosting, invites: [])
        expect(counts.all == unified.count, "10 all count matches unified")
        expect(counts.hosting == hosting.count, "10 hosting count matches hosting projection")
        expect(counts.pickups == unified.filter { $0.source == .pickup }.count, "10 pickup count from unified")
        expect(counts.teamEvents == unified.filter { $0.source == .team }.count, "10 team count from unified")
        expect(
            GoingPlayProjection.filteredItems(unified: unified, hosting: hosting, invites: [], filter: .all) == unified,
            "5 filter All is unified feed"
        )
        expect(
            GoingPlayProjection.filteredItems(unified: unified, hosting: hosting, invites: [], filter: .hosting) == hosting,
            "6 filter Hosting uses hosting projection"
        )
        expect(
            GoingPlayProjection.filteredItems(unified: unified, hosting: hosting, invites: [], filter: .pickups)
                .allSatisfy { $0.source == .pickup },
            "8 filter Pickups"
        )
        expect(
            GoingPlayProjection.filteredItems(unified: unified, hosting: hosting, invites: [], filter: .teamEvents)
                .allSatisfy { $0.source == .team },
            "9 filter Team Events"
        )

        let loc = FanTeamScheduleLocationPresentation.displayLocation(
            venueName: nil,
            address: "Jordan River",
            city: "Riverton",
            state: "Riverton, UT"
        )
        expect(!loc.lowercased().contains("riverton, riverton"), "29 location duplicate city removed")
        expect(loc.contains("UT") || loc.contains("Riverton"), "29 location keeps locality")

        expect(L10n.t("going_play_filter", languageCode: lang) != "going_play_filter", "32 filter != raw key")
        expect(L10n.t("going_play_filter", languageCode: "en") == "Filter", "32 Filter")
        expect(L10n.t("going_play_filter_all", languageCode: lang) != "going_play_filter_all", "32 All != raw key")
        expect(L10n.t("going_play_filter_all", languageCode: lang).isEmpty == false, "32 All")
        expect(L10n.t("going_play_filter_hosting", languageCode: lang).isEmpty == false, "32 Hosting")
        expect(L10n.t("going_play_filter_invites", languageCode: lang).isEmpty == false, "32 Invites")
        expect(L10n.t("going_play_filter_pickups", languageCode: lang).isEmpty == false, "32 Pickups")
        expect(L10n.t("going_play_filter_team_events", languageCode: lang).isEmpty == false, "32 Team Events")
        expect(L10n.t("going_play_upcoming", languageCode: lang).isEmpty == false, "5 Upcoming")
        expect(L10n.t("going_play_badge_pickup", languageCode: lang).uppercased().contains("PICKUP"), "13 PICKUP badge")
        expect(L10n.t("going_play_badge_team", languageCode: lang).isEmpty == false, "14 TEAM badge")
        expect(L10n.t("Create Game", languageCode: lang).isEmpty == false, "3 Create Game")
        expect(L10n.t("games_im_going_to", languageCode: lang).isEmpty == false, "watch Games I'm Going To")
        expect(L10n.t("saved_spots", languageCode: lang).isEmpty == false, "watch Favorite Spots")
        expect(L10n.t("no_watch_plans", languageCode: lang).isEmpty == false, "watch empty title kept")
        expect(L10n.t("no_watch_plans_supporting", languageCode: lang).isEmpty == false, "watch empty supporting kept")
        expect(L10n.t("explore_discover", languageCode: lang).isEmpty == false, "explore Discover kept")
        expect(L10n.t("saved_pro_games", languageCode: lang).isEmpty == false, "pro games section kept")
        expect(L10n.t("favorite_team_games", languageCode: lang).isEmpty == false, "favorite team games section kept")
        expect(L10n.t("View Details", languageCode: lang).isEmpty == false, "19 view details")
        expect(L10n.t("action_center_cta_view_event", languageCode: lang).isEmpty == false, "20 view event")
        expect(L10n.t("pickup_playing_clear_from_going", languageCode: lang).isEmpty == false, "24 clear from going")
        expect(L10n.t("going_tab_title", languageCode: "en") == "My Sports", "tab title My Sports")
        expect(L10n.t("going", languageCode: "en") == "Going", "RSVP Going label unchanged")
        expect(
            L10n.t("guide_going_primary", languageCode: "en").localizedCaseInsensitiveContains("hub"),
            "onboarding subtitle is personal hub"
        )
        expect(
            !L10n.t("going_tab_title", languageCode: "en").localizedCaseInsensitiveContains("Going"),
            "tab title does not say Going"
        )
        expect(L10n.t("guide_going_bullet_1", languageCode: "en") == "Games you're playing", "onboarding play bullet")
        expect(L10n.t("guide_going_bullet_5", languageCode: "en") == "Favorite sports spots", "onboarding spots bullet")
        expect(L10n.t("guide_going_demo_event_2", languageCode: "en") == "IMC Team Practice", "demo team practice")
        expect(L10n.t("guide_going_demo_event_4", languageCode: "en") == "Favorite Sports Bar", "demo favorite spot")
        expect(L10n.t("pickup_rating_pending_status", languageCode: lang).isEmpty == false, "23 rating pending")
        expect(GoingParticipationModePlayCount.modeCount == 3, "26 watch/play/pro unchanged count")

        let a11y = GoingPlayProjection.accessibilityLabel(
            item: mixed.first(where: { $0.pickupGameId == leagueId }) ?? mixed[0],
            dateTimeLine: "Aug 20, 2026",
            languageCode: lang
        )
        expect(a11y.lowercased().contains("team") || a11y.lowercased().contains("pickup"), "24 a11y source")

        let scooterTypes = FanTeamEventTypeCatalog.availableTypes(for: "Electric Scooter", canPublishAnnouncements: false)
        expect(scooterTypes.contains(.practice), "8 e-scooter team types")
        let inlineTypes = FanTeamEventTypeCatalog.availableTypes(for: "Inline Skating", canPublishAnnouncements: false)
        expect(inlineTypes.contains(.practice), "9 inline skating team types")

        expect(GoingPlayProjection.isTeamGameVisibleInGoing(startsAt: now.addingTimeInterval(60), endsAt: nil, now: now), "19 upcoming visible")

        if failures == 0 {
            print("[GoingPlayTest] ALL PASSED")
        } else {
            print("[GoingPlayTest] FAILURES=\(failures)")
            assertionFailure("GoingPlaySelfTests failed: \(failures)")
        }
    }
}

private enum GoingParticipationModePlayCount {
    static let modeCount = 3
}
#endif
