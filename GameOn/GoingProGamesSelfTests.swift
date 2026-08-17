import Foundation

#if DEBUG
enum GoingProGamesSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[GoingProGamesTest] PASS \(name)")
            } else {
                failures += 1
                print("[GoingProGamesTest] FAIL \(name)")
            }
        }

        let now = Date()
        let savedOnly = game(id: "saved-1", home: "Padres", away: "Dodgers", start: now.addingTimeInterval(3600))
        let favoriteOnly = FavoriteTeamProGame(
            game: game(id: "fav-1", home: "Celtics", away: "Bulls", start: now.addingTimeInterval(7200)),
            favoriteTeamID: "nba-celtics",
            favoriteTeamName: "Celtics"
        )
        let bothSaved = game(id: "both-1", home: "Lakers", away: "Jazz", start: now.addingTimeInterval(1800))
        let bothFavorite = FavoriteTeamProGame(
            game: game(id: "both-1", home: "Lakers", away: "Jazz", start: now.addingTimeInterval(1800)),
            favoriteTeamID: "nba-jazz",
            favoriteTeamName: "Jazz"
        )
        let live = game(
            id: "live-1",
            home: "Stars",
            away: "Avalanche",
            start: now.addingTimeInterval(-1200),
            status: .live,
            scoreHome: 3,
            scoreAway: 2
        )

        let unified = GoingProGamesProjection.unified(
            saved: [savedOnly, bothSaved],
            favorite: [favoriteOnly, bothFavorite]
        )
        expect(unified.count == 3, "1 unified All has 3 unique games")
        expect(unified.filter { $0.game.stableKey == "both-1" }.count == 1, "15 both reasons appear once")
        expect(unified.contains { $0.game.stableKey == "both-1" && $0.isSaved && $0.involvesFavoriteTeam }, "15 both badges")
        expect(unified.contains { $0.game.stableKey == "saved-1" && $0.isSaved && !$0.involvesFavoriteTeam }, "13 saved-only")
        expect(unified.contains { $0.game.stableKey == "fav-1" && !$0.isSaved && $0.involvesFavoriteTeam }, "14 favorite-only")

        let counts = GoingProGamesProjection.filterCounts(unified)
        expect(counts.all == 3, "10 All count")
        expect(counts.saved == 2, "11 Saved count")
        expect(counts.favoriteTeams == 2, "12 Favorite Teams count")

        let savedFilter = GoingProGamesProjection.filtered(unified, filter: .saved)
        expect(savedFilter.count == 2, "11 Saved filter")
        expect(savedFilter.contains { $0.game.stableKey == "both-1" }, "16 both appears in Saved")
        expect(!savedFilter.contains { $0.game.stableKey == "fav-1" }, "11 favorite-only excluded from Saved")

        let favoriteFilter = GoingProGamesProjection.filtered(unified, filter: .favoriteTeams)
        expect(favoriteFilter.count == 2, "12 Favorite Teams filter")
        expect(favoriteFilter.contains { $0.game.stableKey == "both-1" }, "16 both appears in Favorite Teams")
        expect(!favoriteFilter.contains { $0.game.stableKey == "saved-1" }, "12 saved-only excluded from Favorite Teams")

        let withLive = GoingProGamesProjection.unified(saved: [live, savedOnly], favorite: [])
        expect(withLive.first?.game.stableKey == "live-1", "18 LIVE sorts first")
        expect(withLive.map(\.id) == withLive.map(\.game.stableKey), "9 canonical id is stableKey")

        expect(
            GoingProGamesProjection.matchupTitle(for: bothSaved) == "Jazz @ Lakers",
            "14 NBA matchup uses @"
        )
        expect(
            GoingProGamesProjection.matchupSeparator(for: .soccer) == "vs",
            "37 soccer uses vs"
        )

        let soccer = game(
            id: "soccer-1",
            home: "Barcelona",
            away: "Real Madrid",
            start: now.addingTimeInterval(86400),
            sport: "Soccer",
            league: "UEFA Champions League"
        )
        expect(
            GoingProGamesProjection.matchupTitle(for: soccer) == "Real Madrid vs Barcelona",
            "37 soccer matchup"
        )

        expect(
            Set(unified.map(\.id)).count == unified.count,
            "17 no duplicate ids in one feed"
        )

        expect(L10n.t("going_pro_upcoming", languageCode: "en") == "Upcoming Pro Games", "34 upcoming key kept")
        expect(L10n.t("going_play_upcoming", languageCode: "en") == "Upcoming", "Pro Games subsection heading is Upcoming")
        expect(L10n.t("intent_watch", languageCode: "en") == "Watch", "Watch tab label kept")
        expect(L10n.t("intent_play", languageCode: "en") == "Play", "Play tab label kept")
        expect(L10n.t("pro_games", languageCode: "en") == "Pro Games", "Pro Games tab label kept")
        expect(L10n.t("going_pro_badge_favorite_team", languageCode: "en") == "Favorite Team", "34 favorite badge")
        expect(L10n.t("going_pro_empty_title", languageCode: "en") == "No pro games yet", "34 empty title")
        expect(L10n.t("going_pro_explore", languageCode: "en") == "Explore Pro Games", "34 explore")
        expect(L10n.t("Favorite Teams", languageCode: "en") == "Favorite Teams", "34 Favorite Teams")
        expect(L10n.t("Team Alerts", languageCode: "en") == "Team Alerts", "34 Team Alerts")
        expect(GoingProGamesFilter.allCases == [.all, .saved, .favoriteTeams], "8 Pro Games filter is All / Saved / Favorite Teams only")
        expect(GoingWatchFilter.allCases == [.all, .games, .favoriteSpots], "Watch Filter cases unchanged")
        expect(GoingPlayFilter.allCases == [.all, .hosting, .invites, .pickups, .teamEvents], "Play Filter cases unchanged")
        expect(L10n.t("going_play_filter", languageCode: "en") == "Filter", "Watch/Play still own Filter")
        expect(L10n.t("going_play_filter_all", languageCode: "en") == "All", "34 All")
        expect(L10n.t("Saved", languageCode: "en") == "Saved", "34 Saved")

        expect(
            !SportsArtworkEnrichmentService.usesDirectTheSportsDBAPI,
            "no direct iOS TheSportsDB call"
        )
        expect(SportsIdentityArtworkMetrics.favoriteSlot == 56, "Favorite Teams identity slot is 56pt")
        expect(SportsIdentityArtworkMetrics.matchupSlot == 28, "matchup logos use the shared 28pt slot")
        expect(SportsIdentityArtworkMetrics.liveScoreboardSlot == 72, "LIVE scoreboard logos use the 72pt slot")
        expect(GoingProLiveScoreboardMetrics.artworkDiameter == 72, "LIVE scoreboard artwork diameter is 72pt")
        expect(GoingProLiveScoreboardMetrics.scoreLayoutPriority == 1, "LIVE score stays visible with long names")
        expect(GoingProLiveScoreboardMetrics.teamNameMaxLines == 2, "LIVE team names wrap to 2 lines")

        let liveSoccer = game(
            id: "live-soccer",
            home: "Vado",
            away: "Inter Milan U23",
            start: now.addingTimeInterval(-4680),
            status: .live,
            scoreHome: 1,
            scoreAway: 1,
            sport: "Soccer",
            league: "Serie C",
            minute: 78
        )
        let liveFavoriteOn = GoingProLiveCardPresentation.make(
            game: liveSoccer,
            involvesFavoriteTeam: true,
            liveAlertsEnabled: true,
            languageCode: "en"
        )
        expect(liveFavoriteOn.usesPremiumActiveGameCard, "LIVE game uses premium active-game card")
        expect(liveFavoriteOn.usesLargeLiveTreatment, "LIVE game uses large LIVE treatment")
        expect(liveFavoriteOn.primaryStatus == .live, "LIVE primary status is live")
        expect(liveFavoriteOn.textualLiveStatusCount == 1, "LIVE card renders exactly one textual LIVE status")
        expect(liveFavoriteOn.textualHalftimeStatusCount == 0, "LIVE card does not also show HT")
        expect(!liveFavoriteOn.showsTitleAreaTeamLogos, "duplicate tiny title-area team logos are removed")
        expect(!liveFavoriteOn.showsTrailingLiveStatusChip, "trailing LIVE pill is removed on LIVE cards")
        expect(!liveFavoriteOn.showsOverlayLiveTextBadge, "overlay LIVE text badge is removed")
        expect(liveFavoriteOn.showsMainScoreboardTeamLogos, "main scoreboard renders both team logos")
        expect(
            !liveFavoriteOn.showsTitleAreaTeamLogos && liveFavoriteOn.showsMainScoreboardTeamLogos,
            "LIVE has one matchup representation"
        )
        expect(liveFavoriteOn.showsBothTeamNames, "both team names render")
        expect(liveFavoriteOn.awayTeamName == "Inter Milan U23", "away name preserved")
        expect(liveFavoriteOn.homeTeamName == "Vado", "home name preserved")
        expect(liveFavoriteOn.scoreRenderCount == 1, "score renders once")
        expect(liveFavoriteOn.awayScore == 1 && liveFavoriteOn.homeScore == 1, "authoritative live score")
        expect(liveFavoriteOn.clockText == "78'", "clock/minute renders when available")
        expect(liveFavoriteOn.showsFavoriteTeamChip, "Favorite Team chip when relevant")
        expect(liveFavoriteOn.showsLiveAlertsOnChip, "Live Alerts ON chip when enabled")
        expect(!liveFavoriteOn.showsLiveAlertsOffChip, "ON state does not also claim OFF")
        expect(liveFavoriteOn.matchupTitle == "Inter Milan U23 vs Vado", "centered matchup uses existing ordering")
        expect(liveFavoriteOn.accessibilityLabel.lowercased().contains("live"), "a11y includes LIVE")
        expect(liveFavoriteOn.accessibilityLabel.contains("Inter Milan U23"), "a11y includes away")
        expect(liveFavoriteOn.accessibilityLabel.contains("Vado"), "a11y includes home")
        expect(liveFavoriteOn.contextChips.contains { if case .sport(_, let label) = $0 { return label == "Soccer" }; return false }, "sport chip is Soccer, not league-specific")

        let liveNonFavoriteOff = GoingProLiveCardPresentation.make(
            game: liveSoccer,
            involvesFavoriteTeam: false,
            liveAlertsEnabled: false,
            languageCode: "en"
        )
        expect(!liveNonFavoriteOff.showsFavoriteTeamChip, "non-favorite game does not show Favorite Team chip")
        expect(!liveNonFavoriteOff.showsLiveAlertsOnChip, "alerts-off state does not claim ON")
        expect(liveNonFavoriteOff.showsLiveAlertsOffChip, "alerts-off still exposes the toggle chip")

        let liveNoAlertsControl = GoingProLiveCardPresentation.make(
            game: liveSoccer,
            involvesFavoriteTeam: false,
            liveAlertsEnabled: nil,
            languageCode: "en"
        )
        expect(!liveNoAlertsControl.showsLiveAlertsOnChip, "missing alerts control does not claim ON")
        expect(!liveNoAlertsControl.showsLiveAlertsOffChip, "missing alerts control does not show OFF")

        let liveNoClock = game(
            id: "live-noclock",
            home: "Celtics",
            away: "Bulls",
            start: now.addingTimeInterval(-600),
            status: .live,
            scoreHome: 88,
            scoreAway: 91,
            sport: "Basketball",
            league: "NBA"
        )
        let liveNoClockPresentation = GoingProLiveCardPresentation.make(
            game: liveNoClock,
            involvesFavoriteTeam: false,
            liveAlertsEnabled: true,
            languageCode: "en"
        )
        expect(liveNoClockPresentation.clockText == nil, "clock omitted when provider does not supply one")
        expect(liveNoClockPresentation.awayScore == 91 && liveNoClockPresentation.homeScore == 88, "2-digit scores preserved")
        expect(GoingProLiveCardPresentation.liveSportChipLabel(for: liveNoClock) == "Basketball", "basketball sport chip is not soccer-specific")

        let nbaClock = game(
            id: "live-nba-clock",
            home: "Lakers",
            away: "Jazz",
            start: now.addingTimeInterval(-2400),
            status: .live,
            scoreHome: 102,
            scoreAway: 99,
            sport: "Basketball",
            league: "NBA",
            liveClockText: "Q4 2:14"
        )
        expect(
            GoingProGamesProjection.liveClockText(for: nbaClock) == "Q4 2:14",
            "non-soccer clock uses provider clock text"
        )
        expect(
            GoingProGamesProjection.liveClockText(for: game(
                id: "live-status-word",
                home: "A",
                away: "B",
                start: now,
                status: .live,
                sport: "Basketball",
                league: "NBA",
                liveClockText: "LIVE"
            )) == nil,
            "status-word clock is omitted"
        )

        let finalGame = game(
            id: "final-1",
            home: "Vado",
            away: "Inter Milan U23",
            start: now.addingTimeInterval(-7200),
            status: .fullTime,
            scoreHome: 1,
            scoreAway: 2,
            sport: "Soccer",
            league: "Serie C",
            minute: 90
        )
        let finalPresentation = GoingProLiveCardPresentation.make(
            game: finalGame,
            involvesFavoriteTeam: true,
            liveAlertsEnabled: true,
            languageCode: "en"
        )
        expect(!finalPresentation.usesPremiumActiveGameCard, "final game does not use active-game LIVE/HT treatment")
        expect(!finalPresentation.usesLargeLiveTreatment, "final game does not use large LIVE treatment")
        expect(finalPresentation.textualLiveStatusCount == 0, "final game has no textual LIVE status")
        expect(finalPresentation.textualHalftimeStatusCount == 0, "final game has no HT status")
        expect(!finalPresentation.showsTitleAreaTeamLogos, "final compact card has no header matchup logos")
        expect(finalPresentation.showsMainScoreboardTeamLogos, "final still renders scoreboard logos")
        expect(finalPresentation.scoreRenderCount == 1, "final scoreboard renders score once")
        expect(finalPresentation.showsTrailingLiveStatusChip, "final keeps trailing status chip")
        expect(
            !finalPresentation.showsTitleAreaTeamLogos && finalPresentation.showsMainScoreboardTeamLogos,
            "final has one matchup representation"
        )

        let upcomingGame = game(
            id: "upcoming-1",
            home: "Barcelona",
            away: "Real Madrid",
            start: now.addingTimeInterval(86400),
            sport: "Soccer",
            league: "La Liga"
        )
        let upcomingPresentation = GoingProLiveCardPresentation.make(
            game: upcomingGame,
            involvesFavoriteTeam: false,
            liveAlertsEnabled: nil,
            languageCode: "en"
        )
        expect(!upcomingPresentation.usesPremiumActiveGameCard, "upcoming game stays compact")
        expect(!upcomingPresentation.usesLargeLiveTreatment, "upcoming game does not use large LIVE treatment")
        expect(upcomingPresentation.textualLiveStatusCount == 0, "upcoming game has no textual LIVE status")
        expect(!upcomingPresentation.showsTitleAreaTeamLogos, "scheduled compact card has no header matchup logos")
        expect(upcomingPresentation.showsMainScoreboardTeamLogos, "scheduled still has a body matchup")
        expect(upcomingPresentation.showsTrailingLiveStatusChip, "scheduled keeps trailing Scheduled chip")
        expect(
            !upcomingPresentation.showsTitleAreaTeamLogos && upcomingPresentation.showsMainScoreboardTeamLogos,
            "scheduled has one matchup representation"
        )

        let redbirdsScheduled = game(
            id: "mlb-redbirds-bulls",
            home: "Durham Bulls",
            away: "Memphis Redbirds",
            start: now,
            sport: "Baseball",
            league: "MLB"
        )
        let redbirdsPresentation = GoingProLiveCardPresentation.make(
            game: redbirdsScheduled,
            involvesFavoriteTeam: true,
            liveAlertsEnabled: true,
            languageCode: "en"
        )
        expect(!redbirdsPresentation.showsTitleAreaTeamLogos, "Redbirds scheduled has no header matchup logos")
        expect(redbirdsPresentation.showsMainScoreboardTeamLogos, "Redbirds scheduled keeps body matchup logos")
        expect(redbirdsPresentation.showsTrailingLiveStatusChip, "Redbirds scheduled keeps share/status cluster")
        expect(redbirdsPresentation.matchupTitle == "Memphis Redbirds @ Durham Bulls", "Redbirds title stays text-only")
        expect(!redbirdsPresentation.usesPremiumActiveGameCard, "Redbirds scheduled stays compact")

        let dreamFinal = game(
            id: "wnba-dream-sun",
            home: "Connecticut Sun",
            away: "Atlanta Dream",
            start: now.addingTimeInterval(-10800),
            status: .fullTime,
            scoreHome: 69,
            scoreAway: 104,
            sport: "Basketball",
            league: "WNBA"
        )
        let dreamPresentation = GoingProLiveCardPresentation.make(
            game: dreamFinal,
            involvesFavoriteTeam: false,
            liveAlertsEnabled: nil,
            languageCode: "en"
        )
        expect(!dreamPresentation.showsTitleAreaTeamLogos, "Dream final has no header matchup logos")
        expect(dreamPresentation.showsMainScoreboardTeamLogos, "Dream final keeps scoreboard logos")
        expect(dreamPresentation.scoreRenderCount == 1, "Dream final scoreboard renders once")
        expect(dreamPresentation.awayScore == 104 && dreamPresentation.homeScore == 69, "Dream final score unchanged")
        expect(dreamPresentation.showsTrailingLiveStatusChip, "Dream final keeps share/clear cluster")
        expect(dreamPresentation.matchupTitle == "Atlanta Dream @ Connecticut Sun", "Dream title stays text-only")

        let cardinalsFinal = game(
            id: "mlb-cardinals-cubs",
            home: "Cubs",
            away: "St. Louis Cardinals",
            start: now.addingTimeInterval(-14400),
            status: .fullTime,
            scoreHome: 3,
            scoreAway: 5,
            sport: "Baseball",
            league: "MLB"
        )
        let cardinalsPresentation = GoingProLiveCardPresentation.make(
            game: cardinalsFinal,
            involvesFavoriteTeam: true,
            liveAlertsEnabled: nil,
            languageCode: "en"
        )
        expect(!cardinalsPresentation.showsTitleAreaTeamLogos, "Cardinals final has no header matchup logos")
        expect(cardinalsPresentation.showsMainScoreboardTeamLogos, "Cardinals final keeps scoreboard logos")
        expect(cardinalsPresentation.scoreRenderCount == 1, "Cardinals final scoreboard renders once")
        expect(cardinalsPresentation.showsTrailingLiveStatusChip, "Cardinals final keeps share/clear cluster")
        expect(
            SportsIdentityArtworkMetrics.matchupSlot == 28
                && SportsIdentityArtworkMetrics.liveScoreboardSlot == 72,
            "stable team identity artwork slots unchanged"
        )

        let halfTimeGame = game(
            id: "ht-1",
            home: "Everton",
            away: "Lille",
            start: now.addingTimeInterval(-2700),
            status: .halfTime,
            scoreHome: 1,
            scoreAway: 0,
            sport: "Club Football",
            league: "Club Friendlies",
            minute: 45
        )
        let halfTimePresentation = GoingProLiveCardPresentation.make(
            game: halfTimeGame,
            involvesFavoriteTeam: true,
            liveAlertsEnabled: true,
            languageCode: "en"
        )
        expect(halfTimePresentation.usesPremiumActiveGameCard, "HT uses premium layout")
        expect(halfTimePresentation.usesLargeLiveTreatment, "HT uses the premium active-game card")
        expect(halfTimePresentation.primaryStatus == .halfTime, "HT primary status is halftime")
        expect(halfTimePresentation.textualHalftimeStatusCount == 1, "HT shows exactly one HT/HALFTIME status")
        expect(halfTimePresentation.textualLiveStatusCount == 0, "HT does not also show LIVE")
        expect(!halfTimePresentation.showsTitleAreaTeamLogos, "HT title has no compact matchup logos")
        expect(!halfTimePresentation.showsTrailingLiveStatusChip, "HT does not keep a trailing HT pill")
        expect(halfTimePresentation.showsMainScoreboardTeamLogos, "premium HT card renders both large team logos")
        expect(
            !halfTimePresentation.showsTitleAreaTeamLogos && halfTimePresentation.showsMainScoreboardTeamLogos,
            "HT has one matchup representation"
        )
        expect(halfTimePresentation.scoreRenderCount == 1, "premium HT card renders score once")
        expect(halfTimePresentation.awayScore == 0 && halfTimePresentation.homeScore == 1, "HT score is 0-1")
        expect(halfTimePresentation.clockText == "Halftime", "HT clock slot is Halftime, not LIVE · 45′")
        expect(
            GoingProGamesProjection.statusTimeLine(
                for: halfTimeGame,
                languageCode: "en",
                timeZoneOption: .automatic
            ) == "Halftime",
            "HT compact status line is Halftime, not LIVE"
        )
        expect(
            halfTimePresentation.contextChips.contains { if case .sport(_, let label) = $0 { return label == "Soccer" }; return false },
            "sport chip says Soccer for soccer, not Club Football"
        )
        expect(halfTimePresentation.showsFavoriteTeamChip, "Favorite Team chip unchanged on HT")
        expect(halfTimePresentation.showsLiveAlertsOnChip, "Live Alerts chip unchanged on HT")
        expect(halfTimePresentation.matchupTitle == "Lille vs Everton", "HT matchup title stays text-only")
        expect(halfTimePresentation.accessibilityLabel.lowercased().contains("halftime"), "HT a11y speaks Halftime")
        expect(!halfTimePresentation.accessibilityLabel.lowercased().contains("live"), "HT a11y does not speak LIVE")
        expect(
            GoingProLiveCardPresentation.liveSportChipLabel(for: halfTimeGame) == "Soccer",
            "Club Football maps to Soccer on the sport chip"
        )

        let longNames = game(
            id: "long-names",
            home: "Very Long United Football Club of the Northern Districts",
            away: "Another Extremely Long Athletic Association Name",
            start: now.addingTimeInterval(-900),
            status: .live,
            scoreHome: 12,
            scoreAway: 10,
            sport: "Soccer",
            league: "Friendly",
            minute: 12
        )
        let longPresentation = GoingProLiveCardPresentation.make(
            game: longNames,
            involvesFavoriteTeam: false,
            liveAlertsEnabled: false,
            languageCode: "en"
        )
        expect(longPresentation.showsBothTeamNames, "long team names still render")
        expect(longPresentation.scoreRenderCount == 1, "long names do not drop the score")
        expect(longPresentation.awayScore == 10 && longPresentation.homeScore == 12, "2-digit score survives long names")

        let fallbackArt = SportsIdentityArtworkResolver.resolveProGameTeam(
            teamName: "Unknown Athletic FC",
            badgeURL: nil,
            source: "GoingPro"
        )
        expect(
            {
                if case .verifiedRemote = fallbackArt.kind { return false }
                return true
            }(),
            "artwork fallback works when no badge URL exists"
        )

        expect(
            liveSoccer.proGamePredictionsAreLocked == (Date() > liveSoccer.proGamePredictionLockTime),
            "predictions lock timing unchanged"
        )
        expect(
            upcomingGame.proGamePredictionsAreLocked == (Date() > upcomingGame.proGamePredictionLockTime),
            "upcoming predictions lock timing unchanged"
        )

        expect(L10n.t("Halftime", languageCode: "en") == "Halftime", "Halftime copy reuses existing key")
        expect(L10n.t("going_pro_live_alerts_on", languageCode: "en") == "Live Alerts ON", "Live Alerts ON copy")
        expect(L10n.t("going_pro_live_alerts_off", languageCode: "en") == "Live Alerts OFF", "Live Alerts OFF copy")
        expect(
            !L10n.t("going_pro_live_card_a11y_format", languageCode: "en").contains("going_pro_live_card_a11y_format"),
            "LIVE a11y format resolves"
        )

        let snapshot = SportsArtworkURLStore.shared.pushTestIsolation()
        defer { SportsArtworkURLStore.shared.popTestIsolation(snapshot) }
        let lakersURL = "https://www.thesportsdb.com/images/media/team/badge/lakers.png"
        let psgURL = "https://www.thesportsdb.com/images/media/team/badge/psg.png"
        let liveLakers = LiveMatch(
            id: "going-art-lakers",
            source: "thesportsdb",
            externalId: "1",
            sport: "Basketball",
            homeTeam: "Lakers",
            awayTeam: "Jazz",
            scoreHome: 100,
            scoreAway: 98,
            scoresAreAvailable: true,
            matchStatus: .scheduled,
            rawMatchStatus: nil,
            minute: nil,
            liveClockText: nil,
            league: "NBA",
            sourceLeagueName: "NBA",
            eventName: nil,
            leagueAlternate: nil,
            sourceSportName: nil,
            startTime: now,
            venueName: nil,
            venueCity: nil,
            venueLatitude: nil,
            venueLongitude: nil,
            leagueCountry: nil,
            tvBroadcasts: [],
            timelineEvents: [],
            featuredEventSlug: nil,
            homeTeamBadgeURL: lakersURL,
            awayTeamBadgeURL: "https://www.thesportsdb.com/images/media/team/badge/jazz.png",
            homeTeamProviderId: "134860",
            awayTeamProviderId: "134867"
        )
        if let lakers = FavoriteTeamCatalog.team(id: "nba-lakers"),
           let jazz = FavoriteTeamCatalog.team(id: "basketball-team-jazz") {
            SportsFavoriteArtworkHydration.ingest(favorites: [lakers, jazz], from: [liveLakers])
            let lakersArt = SportsIdentityArtworkResolver.resolve(favoriteTeam: lakers)
            let jazzArt = SportsIdentityArtworkResolver.resolve(favoriteTeam: jazz)
            let cardArt = SportsIdentityArtworkResolver.resolveProGameTeam(
                teamName: "Lakers",
                badgeURL: liveLakers.homeTeamBadgeURL,
                entityID: liveLakers.homeTeamProviderId,
                league: "NBA",
                source: "thesportsdb"
            )
            expect(
                {
                    if case .verifiedRemote = lakersArt.kind { return true }
                    return false
                }(),
                "Utah Jazz / Lakers favorites resolve the same provider path as game cards"
            )
            expect(
                {
                    if case .verifiedRemote = jazzArt.kind { return true }
                    return false
                }(),
                "Utah Jazz favorite resolves provider badge from live payload"
            )
            expect(
                {
                    if case .verifiedRemote = cardArt.kind, case .verifiedRemote = lakersArt.kind {
                        return true
                    }
                    return false
                }(),
                "favorite row uses same resolver as game cards"
            )
        } else {
            expect(false, "Lakers and Jazz catalog identities exist")
        }

        SportsArtworkURLStore.shared.resetForTests()
        SportsArtworkURLStore.shared.ingestTeam(
            providerId: "133714",
            league: "Ligue 1",
            teamName: "Paris Saint-Germain",
            badgeURL: psgURL
        )
        if let mbappe = FavoriteTeamCatalog.team(id: "player-kylian-mbappe") {
            let playerArt = SportsIdentityArtworkResolver.resolve(favoriteTeam: mbappe)
            expect(
                {
                    if case .playerAthleteFallback = playerArt.kind { return true }
                    return false
                }(),
                "Mbappé does not inherit a club logo from cached PSG artwork"
            )
            expect(
                {
                    if case .fanGeoMonogram = playerArt.kind { return false }
                    return true
                }(),
                "Mbappé without a photo uses Person-with-Star, not initials"
            )
        }

        let accessibilityFormattingFailureStart = failures
        for language in L10n.supportedLanguages.map(\.code) {
            let minuteKey = L10n.t("going_pro_live_minute_a11y_format", languageCode: language)
            expect(
                !minuteKey.contains("%@") && !minuteKey.contains("%d") && !minuteKey.contains("%lld"),
                "\(language) minute a11y copy has no printf specifiers"
            )
            expect(
                !minuteKey.isEmpty && minuteKey != "going_pro_live_minute_a11y_format",
                "\(language) minute a11y copy resolves"
            )

            for minute in [45, 78, 90] {
                let liveMinute = GoingProLiveCardPresentation.make(
                    game: game(
                        id: "a11y-soccer-\(language)-\(minute)",
                        home: "Vado",
                        away: "Inter Milan U23",
                        start: now.addingTimeInterval(-4680),
                        status: .live,
                        scoreHome: 1,
                        scoreAway: 1,
                        sport: "Soccer",
                        league: "Serie C",
                        minute: minute
                    ),
                    involvesFavoriteTeam: true,
                    liveAlertsEnabled: true,
                    languageCode: language
                )
                expect(!liveMinute.accessibilityLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(language) LIVE minute \(minute) spoken summary is nonempty")
                expect(liveMinute.accessibilityLabel.contains(String(minute)), "\(language) LIVE minute \(minute) is spoken")
                expect(liveMinute.accessibilityLabel.contains("Inter Milan U23"), "\(language) LIVE minute \(minute) names away")
                expect(liveMinute.accessibilityLabel.contains("Vado"), "\(language) LIVE minute \(minute) names home")
            }

            let halfTimeSpoken = GoingProLiveCardPresentation.make(
                game: game(
                    id: "a11y-ht-\(language)",
                    home: "Vado",
                    away: "Inter Milan U23",
                    start: now.addingTimeInterval(-2700),
                    status: .halfTime,
                    scoreHome: 1,
                    scoreAway: 1,
                    sport: "Soccer",
                    league: "Serie C",
                    minute: 45
                ),
                involvesFavoriteTeam: true,
                liveAlertsEnabled: true,
                languageCode: language
            )
            expect(!halfTimeSpoken.accessibilityLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(language) HT spoken summary is nonempty")
            expect(
                halfTimeSpoken.accessibilityLabel.localizedCaseInsensitiveContains(
                    L10n.t("Halftime", languageCode: language)
                ),
                "\(language) HT spoken summary includes Halftime"
            )
            expect(
                !halfTimeSpoken.accessibilityLabel.localizedCaseInsensitiveContains(
                    L10n.t("LIVE", languageCode: language)
                ),
                "\(language) HT spoken summary does not include LIVE"
            )
            expect(halfTimeSpoken.usesPremiumActiveGameCard, "\(language) HT uses premium card")
            expect(halfTimeSpoken.textualLiveStatusCount == 0, "\(language) HT has no LIVE status")

            let basketballSpoken = GoingProLiveCardPresentation.make(
                game: game(
                    id: "a11y-nba-\(language)",
                    home: "Celtics",
                    away: "Bulls",
                    start: now.addingTimeInterval(-600),
                    status: .live,
                    scoreHome: 88,
                    scoreAway: 91,
                    sport: "Basketball",
                    league: "NBA",
                    liveClockText: "6:12 3rd"
                ),
                involvesFavoriteTeam: false,
                liveAlertsEnabled: true,
                languageCode: language
            )
            expect(!basketballSpoken.accessibilityLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(language) basketball clock spoken summary is nonempty")
            expect(basketballSpoken.accessibilityLabel.contains("6:12 3rd"), "\(language) basketball clock is spoken")

            let footballSpoken = GoingProLiveCardPresentation.make(
                game: game(
                    id: "a11y-nfl-\(language)",
                    home: "Chiefs",
                    away: "Bills",
                    start: now.addingTimeInterval(-1800),
                    status: .live,
                    scoreHome: 21,
                    scoreAway: 17,
                    sport: "American Football",
                    league: "NFL",
                    liveClockText: "Q2 4:15"
                ),
                involvesFavoriteTeam: false,
                liveAlertsEnabled: nil,
                languageCode: language
            )
            expect(!footballSpoken.accessibilityLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(language) football clock spoken summary is nonempty")
            expect(footballSpoken.accessibilityLabel.contains("Q2 4:15"), "\(language) football clock is spoken")

            let baseballSpoken = GoingProLiveCardPresentation.make(
                game: game(
                    id: "a11y-mlb-\(language)",
                    home: "Cubs",
                    away: "Cardinals",
                    start: now.addingTimeInterval(-2400),
                    status: .live,
                    scoreHome: 3,
                    scoreAway: 2,
                    sport: "Baseball",
                    league: "MLB",
                    liveClockText: "BOT 7"
                ),
                involvesFavoriteTeam: false,
                liveAlertsEnabled: nil,
                languageCode: language
            )
            expect(!baseballSpoken.accessibilityLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(language) baseball status spoken summary is nonempty")
            expect(baseballSpoken.accessibilityLabel.contains("BOT 7"), "\(language) baseball status is spoken")
        }
        let accessibilityFormattingFailures = failures - accessibilityFormattingFailureStart
        if accessibilityFormattingFailures == 0 {
            print("[GoingProLiveAccessibilityFormattingTest] ALL PASSED")
        } else {
            print("[GoingProLiveAccessibilityFormattingTest] FAILURES=\(accessibilityFormattingFailures)")
        }

        if failures == 0 {
            print("[GoingProGamesTest] ALL PASSED")
        } else {
            print("[GoingProGamesTest] FAILURES=\(failures)")
            assertionFailure("GoingProGamesSelfTests failed: \(failures)")
        }
    }

    private static func game(
        id: String,
        home: String,
        away: String,
        start: Date,
        status: MatchStatus = .scheduled,
        scoreHome: Int = 0,
        scoreAway: Int = 0,
        sport: String = "Basketball",
        league: String = "NBA",
        minute: Int? = nil,
        liveClockText: String? = nil
    ) -> SavedProGame {
        SavedProGame(
            id: id,
            source: "test",
            externalId: id,
            homeTeam: home,
            awayTeam: away,
            league: league,
            sport: sport,
            startTime: start,
            matchStatus: status,
            scoreHome: scoreHome,
            scoreAway: scoreAway,
            featuredEventSlug: nil,
            tvSummary: nil,
            minute: minute,
            liveClockText: liveClockText,
            savedAt: start
        )
    }
}
#endif
