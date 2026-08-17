import Foundation

#if DEBUG
enum LiveFeaturedMatchupPresentationSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[LiveFeaturedMatchupTest] PASS \(name)")
            } else {
                failures += 1
                print("[LiveFeaturedMatchupTest] FAIL \(name)")
            }
        }

        let snapshot = SportsArtworkURLStore.shared.pushTestIsolation()
        defer { SportsArtworkURLStore.shared.popTestIsolation(snapshot) }

        expect(
            SportsIdentityArtworkMetrics.featuredMatchupSlot == 52,
            "52pt slot"
        )
        expect(
            LiveFeaturedMatchupPresentation.artworkDiameter == 52,
            "featured matchup artwork diameter is 52pt"
        )
        expect(
            LiveFeaturedMatchupPresentation.usesSportsIdentityArtworkView,
            "uses SportsIdentityArtworkView"
        )
        expect(
            LiveFeaturedMatchupPresentation.usesEqualWidthTeamColumns
                && LiveFeaturedMatchupPresentation.centersScore,
            "centered score"
        )
        expect(
            LiveFeaturedMatchupPresentation.teamNameMaxLines == 2,
            "long team names"
        )
        expect(
            LiveFeaturedMatchupPresentation.preservesWatchNearby,
            "Watch Nearby preserved"
        )
        expect(
            LiveFeaturedMatchupPresentation.preservesFavoriteTeamSelection,
            "favorite-team selection preserved"
        )
        expect(
            !SportsArtworkEnrichmentService.usesDirectTheSportsDBAPI,
            "no direct TheSportsDB from iOS"
        )

        let minnesotaURL = "https://www.thesportsdb.com/images/media/team/badge/minnesota.png"
        let rslURL = "https://www.thesportsdb.com/images/media/team/badge/rsl.png"
        let redbullsURL = "https://www.thesportsdb.com/images/media/team/badge/redbulls.png"
        let atlantaURL = "https://www.thesportsdb.com/images/media/team/badge/atlanta.png"

        let liveMLS = sampleMatch(
            id: "mls-live-featured",
            away: "Minnesota United",
            home: "Real Salt Lake",
            awayScore: 1,
            homeScore: 0,
            status: .live,
            awayBadge: minnesotaURL,
            homeBadge: rslURL,
            awayId: "134794",
            homeId: "134779"
        )
        SportsArtworkURLStore.shared.ingestLiveMatch(liveMLS)
        let liveModel = LiveFeaturedMatchupPresentation.model(from: liveMLS, showsWatchNearby: true)
        expect(liveModel.isLive && !liveModel.isFinal, "Minnesota United vs Real Salt Lake LIVE")
        expect(liveModel.away.teamName == "Minnesota United" && liveModel.home.teamName == "Real Salt Lake", "LIVE matchup names")
        expect(liveModel.awayScore == 1 && liveModel.homeScore == 0 && liveModel.scoresAvailable, "LIVE score preserved")
        expect(liveModel.away.passesProviderID && liveModel.home.passesProviderID, "provider IDs passed")
        expect(liveModel.away.passesLeagueContext && liveModel.leagueLine == "Major League Soccer", "league context passed")
        expect(liveModel.showsWatchNearby, "Watch Nearby preserved on LIVE featured card")
        expect(
            LiveFeaturedMatchupPresentation.isVerifiedRemote(
                LiveFeaturedMatchupPresentation.resolveArtwork(liveModel.away)
            ) && LiveFeaturedMatchupPresentation.isVerifiedRemote(
                LiveFeaturedMatchupPresentation.resolveArtwork(liveModel.home)
            ),
            "both logos available"
        )

        let finalMLS = sampleMatch(
            id: "mls-final-featured",
            away: "New York Red Bulls",
            home: "Atlanta United",
            awayScore: 2,
            homeScore: 2,
            status: .fullTime,
            awayBadge: redbullsURL,
            homeBadge: atlantaURL,
            awayId: "134776",
            homeId: "134777"
        )
        SportsArtworkURLStore.shared.ingestLiveMatch(finalMLS)
        let finalModel = LiveFeaturedMatchupPresentation.model(from: finalMLS, showsWatchNearby: true)
        expect(finalModel.isFinal && !finalModel.isLive, "New York Red Bulls vs Atlanta United FINAL")
        expect(finalModel.awayScore == 2 && finalModel.homeScore == 2, "FINAL score preserved")
        expect(finalModel.away.passesProviderID && finalModel.home.passesProviderID, "FINAL provider IDs passed")
        expect(finalModel.home.passesLeagueContext, "FINAL league context passed")

        let oneMissing = sampleMatch(
            id: "mls-one-logo",
            away: "Portland Timbers Test XI",
            home: "Seattle Sounders Test XI",
            awayScore: 0,
            homeScore: 0,
            status: .live,
            awayBadge: minnesotaURL,
            homeBadge: nil,
            awayId: "test-away-provider",
            homeId: nil
        )
        let oneMissingModel = LiveFeaturedMatchupPresentation.model(from: oneMissing, showsWatchNearby: true)
        expect(
            LiveFeaturedMatchupPresentation.isVerifiedRemote(
                LiveFeaturedMatchupPresentation.resolveArtwork(oneMissingModel.away)
            ) && LiveFeaturedMatchupPresentation.isMissingOfficialLogo(
                LiveFeaturedMatchupPresentation.resolveArtwork(oneMissingModel.home)
            ),
            "one logo missing"
        )

        let bothMissing = sampleMatch(
            id: "mls-no-logos",
            away: "Minnesota United FC Extra Long Name",
            home: "Real Salt Lake City Extra Long Name",
            awayScore: 3,
            homeScore: 1,
            status: .live,
            awayBadge: nil,
            homeBadge: nil,
            awayId: nil,
            homeId: nil
        )
        let bothMissingModel = LiveFeaturedMatchupPresentation.model(from: bothMissing, showsWatchNearby: false)
        expect(
            LiveFeaturedMatchupPresentation.isMissingOfficialLogo(
                LiveFeaturedMatchupPresentation.resolveArtwork(bothMissingModel.away)
            ) && LiveFeaturedMatchupPresentation.isMissingOfficialLogo(
                LiveFeaturedMatchupPresentation.resolveArtwork(bothMissingModel.home)
            ),
            "both logos missing"
        )
        expect(
            bothMissingModel.away.teamName.count > 20 && bothMissingModel.home.teamName.count > 20,
            "long team names wrap using 2-line slot"
        )

        if failures == 0 {
            print("[LiveFeaturedMatchupTest] ALL PASSED")
        } else {
            print("[LiveFeaturedMatchupTest] FAILURES=\(failures)")
            assertionFailure("LiveFeaturedMatchupPresentationSelfTests failed: \(failures)")
        }
    }

    private static func sampleMatch(
        id: String,
        away: String,
        home: String,
        awayScore: Int,
        homeScore: Int,
        status: MatchStatus,
        awayBadge: String?,
        homeBadge: String?,
        awayId: String?,
        homeId: String?
    ) -> LiveMatch {
        LiveMatch(
            id: id,
            source: "thesportsdb",
            externalId: id,
            sport: "Soccer",
            homeTeam: home,
            awayTeam: away,
            scoreHome: homeScore,
            scoreAway: awayScore,
            scoresAreAvailable: true,
            matchStatus: status,
            rawMatchStatus: status.rawValue,
            minute: status == .live ? 67 : nil,
            liveClockText: status == .live ? "67'" : nil,
            league: "Major League Soccer",
            sourceLeagueName: "Major League Soccer",
            eventName: nil,
            leagueAlternate: "MLS",
            sourceSportName: "Soccer",
            startTime: Date(),
            venueName: nil,
            venueCity: nil,
            venueLatitude: nil,
            venueLongitude: nil,
            leagueCountry: "USA",
            tvBroadcasts: [],
            timelineEvents: [],
            featuredEventSlug: nil,
            homeTeamBadgeURL: homeBadge,
            awayTeamBadgeURL: awayBadge,
            homeTeamProviderId: homeId,
            awayTeamProviderId: awayId
        )
    }
}
#endif
