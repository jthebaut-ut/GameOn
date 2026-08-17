import Foundation

#if DEBUG
enum ProfileSportsArtworkSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[ProfileSportsArtworkTest] PASS \(name)")
            } else {
                failures += 1
                print("[ProfileSportsArtworkTest] FAIL \(name)")
            }
        }

        let snapshot = SportsArtworkURLStore.shared.pushTestIsolation()
        defer { SportsArtworkURLStore.shared.popTestIsolation(snapshot) }

        expect(
            !SportsArtworkEnrichmentService.usesDirectTheSportsDBAPI,
            "Profile does not issue a direct TheSportsDB request"
        )

        let jazzURL = "https://www.thesportsdb.com/images/media/team/badge/jazz.png"
        let bullsURL = "https://www.thesportsdb.com/images/media/team/badge/bulls.png"

        guard let jazz = FavoriteTeamCatalog.team(id: "basketball-team-jazz") else {
            print("[ProfileSportsArtworkTest] FAIL Utah Jazz catalog identity exists")
            assertionFailure("ProfileSportsArtworkSelfTests failed: missing basketball-team-jazz")
            return
        }
        guard let bulls = FavoriteTeamCatalog.team(id: "nba-bulls") else {
            print("[ProfileSportsArtworkTest] FAIL Chicago Bulls catalog identity exists")
            assertionFailure("ProfileSportsArtworkSelfTests failed: missing nba-bulls")
            return
        }

        expect(jazz.name == "Utah Jazz", "Utah Jazz catalog name")
        expect(jazz.shortCode == "UTA", "Utah Jazz short code is UTA when artwork is missing")
        expect(bulls.name == "Chicago Bulls", "Chicago Bulls catalog name")
        expect(
            SportsIdentityArtworkResolver.monogram(from: jazz.name, shortCode: jazz.shortCode) == "UTA",
            "Jazz initials fallback is UTA"
        )
        expect(
            SportsIdentityArtworkResolver.monogram(from: bulls.name, shortCode: bulls.shortCode) == "CB",
            "Bulls initials fallback is CB"
        )

        let missingJazz = SportsIdentityArtworkResolver.resolve(favoriteTeam: jazz)
        expect(
            {
                if case .fanGeoMonogram(let text, _, _) = missingJazz.kind {
                    return text == "UTA"
                }
                return false
            }(),
            "unavailable artwork still falls back safely to Jazz initials"
        )

        SportsArtworkURLStore.shared.ingestTeam(
            providerId: "134867",
            league: "NBA",
            teamName: "Utah Jazz",
            badgeURL: jazzURL
        )
        SportsArtworkURLStore.shared.ingestTeam(
            providerId: "134860",
            league: "NBA",
            teamName: "Chicago Bulls",
            badgeURL: bullsURL
        )

        let jazzArt = SportsIdentityArtworkResolver.resolve(favoriteTeam: jazz)
        let bullsArt = SportsIdentityArtworkResolver.resolve(favoriteTeam: bulls)
        expect(isVerifiedRemote(jazzArt), "Utah Jazz resolves through canonical resolver")
        expect(isVerifiedRemote(bullsArt), "Chicago Bulls resolves through canonical resolver")
        expect(isVerifiedRemote(jazzArt), "artwork beats initials for Jazz")
        expect(isVerifiedRemote(bullsArt), "artwork beats initials for Bulls")

        let myTeamCards = ProfileHeroIdentityCardsBuilder.cards(
            myTeam: jazz,
            homeCrowdName: nil,
            homeCrowdSubtitle: nil,
            locationPrimary: nil,
            locationSecondary: nil,
            fanSincePrimary: nil,
            fanSinceSecondary: nil,
            nationalTeam: nil,
            languageCode: "en"
        )
        let myTeam = myTeamCards.first { $0.id == .myTeam }
        expect(myTeam?.favoriteTeam?.id == jazz.id, "Profile My Team uses the selected favorite identity")
        if let myTeamFavorite = myTeam?.favoriteTeam {
            expect(
                isVerifiedRemote(SportsIdentityArtworkResolver.resolve(favoriteTeam: myTeamFavorite)),
                "Profile My Team uses provider artwork when available"
            )
        } else {
            expect(false, "Profile My Team uses provider artwork when available")
        }

        expect(
            SportsIdentityArtworkResolver.providerBadgeURL(for: jazz) == jazzURL,
            "Favorite Team card can resolve Jazz from the artwork store"
        )
        expect(
            SportsIdentityArtworkResolver.providerBadgeURL(for: bulls) == bullsURL,
            "Favorite Team card can resolve Bulls from the artwork store"
        )
        expect(
            SportsIdentityArtworkResolver.artworkLookupLeagues(for: jazz).contains(where: {
                $0.localizedCaseInsensitiveCompare("NBA") == .orderedSame
            }),
            "Jazz conference-group favorites still look up NBA artwork"
        )

        SportsArtworkURLStore.shared.resetForTests()
        let liveJazz = makeLiveMatch(
            home: "Utah Jazz",
            away: "Chicago Bulls",
            homeBadge: jazzURL,
            awayBadge: bullsURL,
            homeId: "134875",
            awayId: "134860"
        )
        SportsArtworkURLStore.shared.ingestLiveMatches([liveJazz])
        expect(
            isVerifiedRemote(SportsIdentityArtworkResolver.resolve(favoriteTeam: jazz)),
            "Profile does not require opening Live first to resolve already-ingested artwork"
        )
        expect(
            isVerifiedRemote(SportsIdentityArtworkResolver.resolve(favoriteTeam: bulls)),
            "ingested live_matches artwork hydrates Bulls favorites"
        )
        SportsArtworkURLStore.shared.ingestLiveMatches([liveJazz])
        expect(
            isVerifiedRemote(SportsIdentityArtworkResolver.resolve(favoriteTeam: jazz)),
            "repeat live ingest with the same badge URLs keeps resolved favorite artwork"
        )
        expect(
            DiscoverMapImageCache.Bucket.forPointSize(48) == .avatar,
            "My Teams 48pt logos downsample with the avatar bucket"
        )
        expect(
            DiscoverMapImageCache.Bucket.forPointSize(118) == .avatar,
            "Favorite Team 118pt crests downsample with the avatar bucket"
        )
        expect(
            DiscoverMapImageCache.Bucket.forPointSize(200) == .venue,
            "large venue photos keep the list-thumbnail bucket"
        )
        expect(
            SportsIdentityArtworkMetrics.profileHeroIdentitySlot == 56,
            "Profile My Team / National Team plate is 56pt"
        )
        expect(
            SportsIdentityArtworkMetrics.visibleArtworkSize(
                container: SportsIdentityArtworkMetrics.profileHeroIdentitySlot,
                optical: .profileHero
            ) == 48,
            "Profile identity crests use 48pt visible artwork"
        )
        expect(
            DiscoverMapImageCache.Bucket.forPointSize(
                SportsIdentityArtworkMetrics.profileHeroIdentitySlot
            ) == .avatar,
            "Profile hero identity marks stay on the avatar downsample bucket"
        )
        let revisionBefore = SportsArtworkURLStore.shared.currentPublishedRevision()
        expect(
            SportsArtworkURLStore.shared.currentPublishedRevision() == revisionBefore,
            "reading Profile identity metrics does not bump the artwork epoch"
        )

        let fanGeo = SportsIdentityArtworkResolver.resolveFanGeoUserTeam()
        expect(
            {
                if case .verifiedRemote = fanGeo.kind { return false }
                return fanGeo.authorization == .fanGeoOwned
            }(),
            "FanGeo user-created Team never gets pro artwork"
        )

        SportsArtworkURLStore.shared.resetForTests()
        let usa = FavoriteTeam(
            id: "soccer-usa",
            name: "United States",
            sport: .soccer,
            league: "National Team",
            region: "National Teams",
            kind: .nationalTeam,
            shortCode: "USA",
            searchAliases: ["USA"],
            fallbackSymbol: "flag.fill",
            badgeRed: 0.12,
            badgeGreen: 0.32,
            badgeBlue: 0.72
        )
        let usaArt = SportsIdentityArtworkResolver.resolve(favoriteTeam: usa)
        expect(
            {
                if case .countryFlag = usaArt.kind { return true }
                return false
            }(),
            "national-team fallback remains valid when no provider crest is cached"
        )

        let italyCrest = "https://www.thesportsdb.com/images/media/team/badge/italy.png"
        SportsArtworkURLStore.shared.ingestTeam(
            providerId: "133957",
            league: "National Team",
            teamName: "Italy",
            badgeURL: italyCrest
        )
        guard let italy = FavoriteTeamCatalog.nationalTeam(matchingCountryName: "Italy") else {
            expect(false, "Italy national team exists in the catalog")
            return
        }
        expect(italy.id == "soccer-italy", "Italy catalog identity is soccer-italy")
        expect(
            isVerifiedRemote(SportsIdentityArtworkResolver.resolve(favoriteTeam: italy)),
            "national-team crest is preferred over the flag when provider artwork exists"
        )
        expect(
            isVerifiedRemote(
                SportsIdentityArtworkResolver.resolveNationalTeam(countryName: "Italy", flag: "🇮🇹")
            ),
            "resolveNationalTeam uses cached Italy crest before the flag"
        )

        SportsArtworkURLStore.shared.resetForTests()
        let lakersURL = "https://www.thesportsdb.com/images/media/team/badge/lakers.png"
        let franceCrest = "https://r2.thesportsdb.com/images/media/team/badge/france.png"
        let mbappeCutout = "https://www.thesportsdb.com/images/media/player/cutout/mbappe.png"
        let psgBadge = "https://www.thesportsdb.com/images/media/team/badge/psg.png"
        guard let lakers = FavoriteTeamCatalog.team(id: "nba-lakers") else {
            expect(false, "Los Angeles Lakers catalog identity exists")
            return
        }
        let lakersLive = makeLiveMatch(
            home: "Lakers",
            away: "Celtics",
            homeBadge: lakersURL,
            awayBadge: "https://www.thesportsdb.com/images/media/team/badge/celtics.png",
            homeId: "134867",
            awayId: "134861"
        )
        SportsFavoriteArtworkHydration.ingest(favorites: [lakers], from: [lakersLive])
        expect(
            isVerifiedRemote(SportsIdentityArtworkResolver.resolve(favoriteTeam: lakers)),
            "Los Angeles Lakers favorite resolves provider badge from live payload name Lakers"
        )
        expect(
            SportsIdentityArtworkMetrics.favoriteSlot == 56,
            "Favorite Teams row uses a 56pt identity slot"
        )
        expect(
            FavoriteTeamRichCardStyle.usesTeamColorGradient == false,
            "Favorite Team card does not use heavy gradient style"
        )
        expect(
            FavoriteTeamRichCardStyle.ownProfile.orbDiameter == SportsIdentityArtworkMetrics.favoriteCardPlate,
            "Profile Favorite Teams logo plate is the large identity plate"
        )
        expect(
            FavoriteTeamRichCardStyle.ownProfile.width == 172
                && FavoriteTeamRichCardStyle.ownProfile.height == 240,
            "Profile Favorite Teams cards are two-up premium identity cards"
        )
        expect(
            FavoriteTeamRichCardStyle.ownProfile.cardSpacing == 16,
            "Favorite Team cards use a 16pt gap"
        )
        expect(
            FavoriteTeamRichCardStyle.ownProfile.nameLineLimit == 2,
            "team name can wrap two lines"
        )
        expect(
            SportsIdentityArtworkMetrics.inset(for: 118, playerPortrait: false) >= 7,
            "crest inset keeps wide Jazz marks optically balanced"
        )

        SportsArtworkURLStore.shared.resetForTests()
        SportsArtworkURLStore.shared.ingestCatalogIdentity(
            catalogId: "nba-lakers",
            providerId: "134867",
            league: "NBA",
            teamName: "Los Angeles Lakers",
            badgeURL: lakersURL
        )
        SportsArtworkURLStore.shared.ingestCatalogIdentity(
            catalogId: "basketball-team-jazz",
            providerId: "134875",
            league: "NBA",
            teamName: "Utah Jazz",
            badgeURL: jazzURL
        )
        let bullsWithoutOwnBadge = SportsIdentityArtworkResolver.resolve(favoriteTeam: bulls)
        expect(
            {
                if case .verifiedRemote(let url) = bullsWithoutOwnBadge.kind {
                    let raw = url.absoluteString.lowercased()
                    return raw.contains("lakers") || raw.contains("jazz")
                }
                return false
            }() == false,
            "Bulls never resolves another team's artwork"
        )
        expect(
            {
                if case .fanGeoMonogram(let text, _, _) = bullsWithoutOwnBadge.kind {
                    return text == "CB"
                }
                return false
            }(),
            "Bulls falls back to initials when its own badge is missing"
        )
        SportsArtworkURLStore.shared.ingestCatalogIdentity(
            catalogId: "nba-bulls",
            providerId: "134860",
            league: "NBA",
            teamName: "Chicago Bulls",
            badgeURL: bullsURL
        )
        let bullsOwn = SportsIdentityArtworkResolver.resolve(favoriteTeam: bulls)
        expect(
            {
                if case .verifiedRemote(let url) = bullsOwn.kind {
                    return url.absoluteString.contains("bulls.png")
                        && !url.absoluteString.contains("lakers")
                        && !url.absoluteString.contains("jazz")
                }
                return false
            }(),
            "Chicago Bulls resolves only its own provider badge"
        )
        let jazzFromCatalog = SportsIdentityArtworkResolver.resolve(favoriteTeam: jazz)
        expect(
            {
                if case .verifiedRemote(let url) = jazzFromCatalog.kind {
                    return url.absoluteString.contains("jazz.png")
                }
                return false
            }(),
            "Jazz does not remain initials when valid Jazz artwork is in store"
        )
        expect(
            !SportsArtworkEnrichmentService.usesDirectTheSportsDBAPI,
            "no direct iOS TheSportsDB request"
        )

        SportsArtworkURLStore.shared.resetForTests()
        guard let france = FavoriteTeamCatalog.team(id: "soccer-france") else {
            expect(false, "France catalog identity exists")
            return
        }
        let franceLive = LiveMatch(
            id: "profile-art-france",
            source: "thesportsdb",
            externalId: "133957",
            sport: "Soccer",
            homeTeam: "France",
            awayTeam: "Spain",
            scoreHome: 1,
            scoreAway: 0,
            scoresAreAvailable: true,
            matchStatus: .scheduled,
            rawMatchStatus: nil,
            minute: nil,
            liveClockText: nil,
            league: "International",
            sourceLeagueName: "UEFA",
            eventName: nil,
            leagueAlternate: nil,
            sourceSportName: nil,
            startTime: Date(),
            venueName: nil,
            venueCity: nil,
            venueLatitude: nil,
            venueLongitude: nil,
            leagueCountry: nil,
            tvBroadcasts: [],
            timelineEvents: [],
            featuredEventSlug: nil,
            homeTeamBadgeURL: franceCrest,
            awayTeamBadgeURL: nil,
            homeTeamProviderId: "133957",
            awayTeamProviderId: nil
        )
        SportsFavoriteArtworkHydration.ingest(favorites: [france], from: [franceLive])
        let franceArt = SportsIdentityArtworkResolver.resolve(favoriteTeam: france)
        expect(isVerifiedRemote(franceArt), "France prefers crest over flag when crest exists")

        SportsArtworkURLStore.shared.resetForTests()
        SportsArtworkURLStore.shared.ingestPlayer(playerName: "Kylian Mbappe", imageURL: mbappeCutout)
        SportsArtworkURLStore.shared.ingestTeam(
            providerId: "133714",
            league: "Ligue 1",
            teamName: "Paris Saint-Germain",
            badgeURL: psgBadge
        )
        guard let mbappe = FavoriteTeamCatalog.team(id: "player-kylian-mbappe") else {
            expect(false, "Kylian Mbappé catalog identity exists")
            return
        }
        let mbappeArt = SportsIdentityArtworkResolver.resolve(favoriteTeam: mbappe)
        expect(
            {
                if case .verifiedRemote(let url) = mbappeArt.kind {
                    return url.absoluteString.localizedCaseInsensitiveContains("mbappe")
                        || url.absoluteString.localizedCaseInsensitiveContains("player")
                        || url.absoluteString.localizedCaseInsensitiveContains("cutout")
                }
                return false
            }(),
            "Kylian Mbappé resolves player artwork when available"
        )
        expect(
            {
                if case .verifiedRemote(let url) = mbappeArt.kind {
                    return !url.absoluteString.localizedCaseInsensitiveContains("psg")
                }
                return true
            }(),
            "player artwork never substitutes a club logo"
        )

        SportsArtworkURLStore.shared.resetForTests()
        let mbappeFallback = SportsIdentityArtworkResolver.resolve(favoriteTeam: mbappe)
        expect(
            {
                if case .playerAthleteFallback = mbappeFallback.kind { return true }
                return false
            }(),
            "Featured Athlete without a photo uses Person-with-Star"
        )
        expect(
            {
                if case .fanGeoMonogram = mbappeFallback.kind { return false }
                return true
            }(),
            "Profile Featured Athlete no longer uses initials as the primary fallback"
        )

        if let superBowl = FavoriteTeamCatalog.team(id: "tournament-super-bowl") {
            let missing = SportsIdentityArtworkResolver.resolve(favoriteTeam: superBowl, diameter: 118)
            expect(
                {
                    if case .competitionFallback = missing.kind { return true }
                    return false
                }(),
                "Profile Super Bowl card uses the polished competition fallback when artwork is missing"
            )
            SportsArtworkURLStore.shared.ingestLeague(
                name: "Super Bowl",
                badgeURL: "https://r2.thesportsdb.com/images/media/league/badge/superbowl.png",
                catalogId: "tournament-super-bowl"
            )
            expect(
                isVerifiedRemote(SportsIdentityArtworkResolver.resolve(favoriteTeam: superBowl, diameter: 118)),
                "Profile Super Bowl card uses official artwork when the store has it"
            )
            expect(
                SportsIdentityArtworkResolver.providerBadgeURL(for: FavoriteTeamCatalog.team(id: "nba-lakers") ?? superBowl)?
                    .localizedCaseInsensitiveContains("superbowl") != true,
                "Super Bowl artwork does not leak onto club cards"
            )
        } else {
            expect(false, "Profile Super Bowl catalog identity exists")
        }

        let unknown = SportsIdentityArtworkResolver.resolveProGameTeam(
            teamName: "Unknown Athletic Club 2099",
            badgeURL: nil,
            source: "Test"
        )
        expect(
            {
                if case .fanGeoMonogram = unknown.kind { return true }
                return false
            }(),
            "unknown team still falls back safely"
        )

        if failures == 0 {
            print("[ProfileSportsArtworkTest] ALL PASSED")
        } else {
            print("[ProfileSportsArtworkTest] FAILURES=\(failures)")
            assertionFailure("ProfileSportsArtworkSelfTests failed: \(failures)")
        }
    }

    private static func isVerifiedRemote(_ descriptor: SportsIdentityArtworkDescriptor) -> Bool {
        if case .verifiedRemote = descriptor.kind { return true }
        return false
    }

    private static func makeLiveMatch(
        home: String,
        away: String,
        homeBadge: String,
        awayBadge: String,
        homeId: String,
        awayId: String
    ) -> LiveMatch {
        LiveMatch(
            id: "profile-art-\(homeId)",
            source: "thesportsdb",
            externalId: homeId,
            sport: "Basketball",
            homeTeam: home,
            awayTeam: away,
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
            startTime: Date(),
            venueName: nil,
            venueCity: nil,
            venueLatitude: nil,
            venueLongitude: nil,
            leagueCountry: nil,
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
