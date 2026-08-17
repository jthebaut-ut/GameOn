import Foundation

#if DEBUG
enum SportsIdentityArtworkSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[SportsIdentityArtworkTest] PASS \(name)")
            } else {
                failures += 1
                print("[SportsIdentityArtworkTest] FAIL \(name)")
            }
        }

        let snapshot = SportsArtworkURLStore.shared.pushTestIsolation()
        defer { SportsArtworkURLStore.shared.popTestIsolation(snapshot) }

        expect(
            !SportsArtworkEnrichmentService.usesDirectTheSportsDBAPI,
            "artwork enrichment does not call TheSportsDB from iOS"
        )

        let lakersURL = "https://www.thesportsdb.com/images/media/team/badge/lakers.png"
        let franceCrest = "https://r2.thesportsdb.com/images/media/team/badge/france.png"
        let mbappeCutout = "https://www.thesportsdb.com/images/media/player/cutout/mbappe.png"
        let nbaBadge = "https://www.thesportsdb.com/images/media/league/badge/nba.png"
        let randomHost = "https://example.test/stolen-logo.png"

        expect(
            SportsArtworkURLStore.isTheSportsDBArtworkURL(lakersURL),
            "TheSportsDB host is recognized"
        )
        expect(
            !SportsArtworkURLStore.isTheSportsDBArtworkURL(randomHost),
            "non-TheSportsDB host is rejected"
        )
        expect(
            SportsArtworkAuthorizationRegistry.authorization(entityID: "nba-lakers", remoteURL: lakersURL)
                == .providerAPIAsIs,
            "TheSportsDB URL is providerAPIAsIs"
        )
        expect(
            SportsArtworkAuthorizationRegistry.authorization(entityID: "nba-lakers", remoteURL: randomHost)
                == .unverified,
            "unknown host stays unverified"
        )

        SportsArtworkURLStore.shared.ingestTeam(
            providerId: "134860",
            league: "NBA",
            teamName: "Los Angeles Lakers",
            badgeURL: lakersURL
        )
        SportsArtworkURLStore.shared.ingestTeam(
            providerId: "133957",
            league: "UEFA",
            teamName: "France",
            badgeURL: franceCrest
        )
        SportsArtworkURLStore.shared.ingestPlayer(playerName: "Kylian Mbappé", imageURL: mbappeCutout)
        SportsArtworkURLStore.shared.ingestLeague(name: "NBA", badgeURL: nbaBadge)

        let lakers = FavoriteTeamCatalog.team(id: "nba-lakers")
            ?? FavoriteTeam(
                id: "nba-lakers",
                name: "Los Angeles Lakers",
                sport: .basketball,
                league: "NBA",
                region: "North America",
                kind: .team,
                shortCode: "LAL",
                searchAliases: [],
                fallbackSymbol: "basketball.fill",
                badgeRed: 0.4,
                badgeGreen: 0.2,
                badgeBlue: 0.6
            )
        let lakersArt = SportsIdentityArtworkResolver.resolve(favoriteTeam: lakers)
        expect(
            {
                if case .verifiedRemote = lakersArt.kind { return true }
                return false
            }(),
            "API badge beats initials for Lakers"
        )
        expect(lakersArt.authorization.allowsOfficialRemoteArtwork, "Lakers artwork is displayable")

        let france = FavoriteTeam(
            id: "soccer-france",
            name: "France",
            sport: .soccer,
            league: "UEFA",
            region: "Europe",
            kind: .nationalTeam,
            shortCode: nil,
            searchAliases: [],
            fallbackSymbol: "soccerball",
            badgeRed: 0.1,
            badgeGreen: 0.2,
            badgeBlue: 0.7
        )
        let franceArt = SportsIdentityArtworkResolver.resolve(favoriteTeam: france)
        expect(
            {
                if case .verifiedRemote = franceArt.kind { return true }
                return false
            }(),
            "national crest beats flag when API artwork exists"
        )

        SportsArtworkURLStore.shared.resetForTests()
        let franceFlagOnly = SportsIdentityArtworkResolver.resolve(favoriteTeam: france)
        expect(
            {
                if case .countryFlag = franceFlagOnly.kind { return true }
                return false
            }(),
            "flag fallback works when no crest is cached"
        )

        SportsArtworkURLStore.shared.ingestTeam(
            providerId: "134860",
            league: "NBA",
            teamName: "Los Angeles Lakers",
            badgeURL: lakersURL
        )
        SportsArtworkURLStore.shared.ingestPlayer(playerName: "Kylian Mbappé", imageURL: mbappeCutout)
        SportsArtworkURLStore.shared.ingestLeague(name: "NBA", badgeURL: nbaBadge)
        SportsArtworkURLStore.shared.ingestTeam(
            providerId: "133957",
            league: "UEFA",
            teamName: "France",
            badgeURL: franceCrest
        )

        let mbappe = FavoriteTeam(
            id: "player-mbappe",
            name: "Kylian Mbappé",
            sport: .soccer,
            league: "Favorite Players",
            region: "Europe",
            kind: .player,
            shortCode: nil,
            searchAliases: [],
            fallbackSymbol: "person.fill",
            badgeRed: 0.2,
            badgeGreen: 0.2,
            badgeBlue: 0.2
        )
        let playerArt = SportsIdentityArtworkResolver.resolve(favoriteTeam: mbappe)
        expect(
            {
                if case .verifiedRemote(let url) = playerArt.kind {
                    return url.absoluteString.localizedCaseInsensitiveContains("mbappe")
                        || url.absoluteString.localizedCaseInsensitiveContains("player")
                        || url.absoluteString.localizedCaseInsensitiveContains("cutout")
                }
                return false
            }(),
            "player artwork prefers player cutout, not club logo"
        )
        if case .verifiedRemote(let url) = playerArt.kind {
            expect(
                !url.absoluteString.localizedCaseInsensitiveContains("lakers"),
                "player resolver does not use Lakers club badge"
            )
        }

        let nba = FavoriteTeam(
            id: "league-nba",
            name: "NBA",
            sport: .basketball,
            league: "NBA",
            region: "North America",
            kind: .league,
            shortCode: nil,
            searchAliases: [],
            fallbackSymbol: "trophy.fill",
            badgeRed: 0.7,
            badgeGreen: 0.2,
            badgeBlue: 0.2
        )
        let leagueArt = SportsIdentityArtworkResolver.resolve(favoriteTeam: nba)
        expect(
            {
                if case .verifiedRemote = leagueArt.kind { return true }
                return false
            }(),
            "league artwork preference"
        )

        if let superBowl = FavoriteTeamCatalog.team(id: "tournament-super-bowl") {
        expect(superBowl.kind == .competition, "Super Bowl is a competition identity")
        expect(superBowl.id == "tournament-super-bowl", "Super Bowl uses a stable competition catalog ID")
        expect(
            !superBowl.id.contains("lx") && !superBowl.id.contains("event-tsdb"),
            "stable Super Bowl identity is not a one-year event ID"
        )
        let superBowlWithoutArt = SportsIdentityArtworkResolver.resolve(favoriteTeam: superBowl, diameter: 118)
        expect(
            {
                if case .competitionFallback = superBowlWithoutArt.kind { return true }
                return false
            }(),
            "competition without artwork uses polished competition fallback"
        )
        expect(
            {
                if case .genericSymbol = superBowlWithoutArt.kind { return false }
                return true
            }(),
            "generic trophy is not selected when the competition fallback exists"
        )
        expect(
            {
                if case .verifiedRemote(let url) = superBowlWithoutArt.kind {
                    return url.absoluteString.localizedCaseInsensitiveContains("lakers")
                        || url.absoluteString.localizedCaseInsensitiveContains("nba")
                        || url.absoluteString.localizedCaseInsensitiveContains("france")
                }
                return false
            }() == false,
            "competition fallback does not use a team logo, league shield, or national flag"
        )
        expect(
            {
                if case .countryFlag = superBowlWithoutArt.kind { return false }
                return true
            }(),
            "competition artwork does not use a national flag"
        )
        expect(superBowlWithoutArt.authorization == .fanGeoOwned, "competition fallback is FanGeo-owned")

        SportsArtworkURLStore.shared.ingestLeague(
            name: "NFL",
            badgeURL: "https://r2.thesportsdb.com/images/media/league/badge/nfl.png",
            catalogId: "league-nfl"
        )
        let superBowlAfterNFL = SportsIdentityArtworkResolver.resolve(favoriteTeam: superBowl)
        expect(
            {
                if case .competitionFallback = superBowlAfterNFL.kind { return true }
                return false
            }(),
            "NFL league artwork does not attach to the stable Super Bowl identity"
        )

        let superBowlBadge = "https://r2.thesportsdb.com/images/media/league/badge/superbowl.png"
        SportsArtworkURLStore.shared.ingestLeague(
            name: "Super Bowl",
            badgeURL: superBowlBadge,
            catalogId: "tournament-super-bowl"
        )
        let superBowlOfficial = SportsIdentityArtworkResolver.resolve(favoriteTeam: superBowl, diameter: 118)
        expect(
            {
                if case .verifiedRemote(let url) = superBowlOfficial.kind {
                    return url.absoluteString.localizedCaseInsensitiveContains("superbowl")
                }
                return false
            }(),
            "Super Bowl/provider identity resolves official artwork when available"
        )
        expect(
            SportsIdentityArtworkResolver.competitionArtworkURL(for: superBowl) == superBowlBadge,
            "shared resolver looks up Super Bowl artwork by catalog ID"
        )
        let followingArt = SportsIdentityArtworkResolver.resolve(favoriteTeam: superBowl, diameter: 52)
        let pickerArt = SportsIdentityArtworkResolver.resolve(favoriteTeam: superBowl, diameter: 36)
        expect(
            {
                if case .verifiedRemote = followingArt.kind, case .verifiedRemote = pickerArt.kind {
                    return true
                }
                return false
            }(),
            "shared resolver behavior is consistent across Profile/Following/picker diameters"
        )
        expect(
            SportsArtworkURLStore.displayURL(from: superBowlBadge, diameter: 28)?
                .absoluteString.hasSuffix("/tiny") == true,
            "compact competition artwork uses the official /tiny variant"
        )
        expect(
            SportsArtworkURLStore.displayURL(from: superBowlBadge, diameter: 118)?
                .absoluteString.hasSuffix("/small") == true,
            "118pt competition artwork uses the official /small variant"
        )
        let visible118 = SportsIdentityArtworkMetrics.visibleArtworkSize(container: 118)
        expect(visible118 >= 70 && visible118 <= 90, "118pt official competition artwork fills 70–90pt")
        expect(
            FanGeoCompetitionFallbackMarkMetrics.trophyFontSize(diameter: 118) >= 70
                && FanGeoCompetitionFallbackMarkMetrics.trophyFontSize(diameter: 118) <= 90,
            "118pt competition fallback trophy fills 70–90pt"
        )
        expect(
            FanGeoCompetitionFallbackMarkMetrics.trophyFontSize(diameter: 28) >= 16
                && FanGeoCompetitionFallbackMarkMetrics.trophyFontSize(diameter: 28) < 28,
            "compact competition fallback remains readable without clipping"
        )
        expect(
            DiscoverMapImageCache.Bucket.forPointSize(118) == .avatar,
            "competition cards reuse the existing remote-image cache bucket"
        )

        SportsArtworkURLStore.shared.ingestLeague(
            name: "Super Bowl",
            badgeURL: "https://example.com/superbowl.png",
            catalogId: "tournament-super-bowl-untrusted"
        )
        expect(
            SportsArtworkURLStore.shared.badgeURL(catalogId: "tournament-super-bowl-untrusted") == nil,
            "trusted-host rules reject non-TheSportsDB competition URLs"
        )
        } else {
            expect(false, "Super Bowl catalog identity exists")
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
            "unknown artwork falls back to monogram"
        )

        let fanGeo = SportsIdentityArtworkResolver.resolveFanGeoUserTeam()
        expect(fanGeo.authorization == .fanGeoOwned, "FanGeo user Team stays FanGeo-owned")
        expect(
            {
                if case .genericSymbol = fanGeo.kind { return true }
                return false
            }(),
            "FanGeo user Team does not resolve to pro artwork"
        )
        expect(
            {
                if case .verifiedRemote = fanGeo.kind { return false }
                return true
            }(),
            "FanGeo user Team ignores cached Lakers badge"
        )

        expect(
            SportsArtworkURLStore.shared.badgeURL(providerId: "134860", teamName: "Wrong Name") == lakersURL,
            "provider-ID matching wins over name"
        )

        let first = SportsArtworkURLStore.displayURL(from: lakersURL, diameter: 28)
        let second = SportsArtworkURLStore.displayURL(from: lakersURL, diameter: 28)
        expect(first == second, "duplicate image URLs coalesce to the same display URL")
        expect(
            first?.absoluteString.hasSuffix("/tiny") == true,
            "small display URLs use official /tiny variant without modifying the badge"
        )
        expect(
            SportsIdentityArtworkMetrics.profileHeroIdentitySlot == 56,
            "Profile hero identity plate is 56pt"
        )
        expect(
            SportsIdentityArtworkMetrics.visibleArtworkSize(
                container: 56,
                optical: .profileHero
            ) == 48,
            "Profile hero visible crest is 48pt"
        )
        expect(
            SportsArtworkURLStore.displayURL(from: lakersURL, diameter: 56)?
                .absoluteString.hasSuffix("/small") == true,
            "56pt Profile marks use official /small, not /tiny"
        )

        let missing = SportsIdentityArtworkResolver.resolveProGameTeam(
            teamName: "Utah Jazz",
            badgeURL: "not a url",
            source: "Test"
        )
        expect(
            {
                if case .verifiedRemote = missing.kind { return false }
                return true
            }(),
            "missing artwork does not break rendering"
        )

        let jazzFromLive = LiveMatch(
            id: "test-jazz",
            source: "thesportsdb",
            externalId: "1",
            sport: "Basketball",
            homeTeam: "Utah Jazz",
            awayTeam: "Los Angeles Lakers",
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
            homeTeamBadgeURL: "https://www.thesportsdb.com/images/media/team/badge/jazz.png",
            awayTeamBadgeURL: lakersURL,
            homeTeamProviderId: "134875",
            awayTeamProviderId: "134867"
        )
        SportsArtworkURLStore.shared.ingestLiveMatch(jazzFromLive)
        let jazzArt = SportsIdentityArtworkResolver.resolveProGameTeam(
            teamName: "Utah Jazz",
            badgeURL: nil,
            entityID: "134875",
            league: "NBA",
            source: "thesportsdb"
        )
        expect(
            {
                if case .verifiedRemote = jazzArt.kind { return true }
                return false
            }(),
            "live-match ingest supplies Jazz badge without a per-row lookup"
        )

        let jazzFavorite = FavoriteTeamCatalog.team(id: "basketball-team-jazz")
        expect(jazzFavorite != nil, "Utah Jazz exists in the favorite catalog")
        if let jazzFavorite {
            expect(
                {
                    if case .verifiedRemote = SportsIdentityArtworkResolver.resolve(favoriteTeam: jazzFavorite).kind {
                        return true
                    }
                    return false
                }(),
                "Utah Jazz favorite resolves through canonical resolver after live ingest"
            )
        }

        let bullsFavorite = FavoriteTeamCatalog.team(id: "nba-bulls")
        expect(bullsFavorite != nil, "Chicago Bulls exists in the favorite catalog")
        if let bullsFavorite {
            SportsArtworkURLStore.shared.ingestTeam(
                providerId: "134870",
                league: "NBA",
                teamName: "Chicago Bulls",
                badgeURL: "https://www.thesportsdb.com/images/media/team/badge/bulls.png"
            )
            expect(
                {
                    if case .verifiedRemote = SportsIdentityArtworkResolver.resolve(favoriteTeam: bullsFavorite).kind {
                        return true
                    }
                    return false
                }(),
                "Chicago Bulls favorite resolves through canonical resolver"
            )
        }

        SportsArtworkURLStore.shared.resetForTests()
        let jazzLiveBadge = "https://www.thesportsdb.com/images/media/team/badge/jazz.png"
        let jazzFromPayload = SportsIdentityArtworkResolver.resolveProGameTeam(
            teamName: "Utah Jazz",
            badgeURL: jazzLiveBadge,
            entityID: "134867",
            league: "NBA",
            source: "thesportsdb"
        )
        expect(
            {
                if case .verifiedRemote = jazzFromPayload.kind { return true }
                return false
            }(),
            "existing live payload badge is used with an empty artwork store"
        )
        expect(
            SportsArtworkURLStore.shared.badgeURL(providerId: "134867", teamName: "Utah Jazz") == nil,
            "payload badge does not require a follow-up team lookup"
        )

        let missingFallsBack = SportsIdentityArtworkResolver.resolveProGameTeam(
            teamName: "Unknown Athletic Club 2099",
            badgeURL: nil,
            source: "Test"
        )
        expect(
            {
                if case .fanGeoMonogram = missingFallsBack.kind { return true }
                return false
            }(),
            "fallback works if artwork unavailable"
        )

        SportsArtworkURLStore.shared.resetForTests()
        SportsArtworkURLStore.shared.ingestCatalogIdentity(
            catalogId: "nba-lakers",
            providerId: "134867",
            league: "NBA",
            teamName: "Los Angeles Lakers",
            badgeURL: lakersURL
        )
        if let bullsFavorite = FavoriteTeamCatalog.team(id: "nba-bulls") {
            let stolen = SportsIdentityArtworkResolver.resolve(favoriteTeam: bullsFavorite)
            expect(
                {
                    if case .verifiedRemote(let url) = stolen.kind {
                        return url.absoluteString.contains("lakers")
                    }
                    return false
                }() == false,
                "Bulls favorite never resolves a Lakers badge"
            )
        }

        SportsArtworkURLStore.shared.resetForTests()
        let athlete = FavoriteTeam(
            id: "player-mbappe",
            name: "Kylian Mbappé",
            sport: .soccer,
            league: "Favorite Players",
            region: "Europe",
            kind: .player,
            shortCode: "KM",
            searchAliases: [],
            fallbackSymbol: "person.fill",
            badgeRed: 0.2,
            badgeGreen: 0.2,
            badgeBlue: 0.2
        )
        expect(athlete.kind.isProfessionalAthlete, "catalog player is a professional athlete")
        let athleteFallback = SportsIdentityArtworkResolver.resolve(favoriteTeam: athlete)
        expect(
            {
                if case .playerAthleteFallback = athleteFallback.kind { return true }
                return false
            }(),
            "player without artwork uses Person-with-Star fallback"
        )
        expect(
            {
                if case .fanGeoMonogram = athleteFallback.kind { return false }
                return true
            }(),
            "initials are not the primary professional-player fallback"
        )
        expect(athleteFallback.authorization == .fanGeoOwned, "player fallback is FanGeo-owned")
        expect(athleteFallback.accessibilityIsDecorative, "player fallback is decorative for VoiceOver")
        expect(
            {
                if case .countryFlag = athleteFallback.kind { return false }
                return true
            }(),
            "player fallback does not use a national flag"
        )
        expect(
            {
                if case .verifiedRemote(let url) = athleteFallback.kind {
                    return url.absoluteString.localizedCaseInsensitiveContains("lakers")
                }
                return true
            }(),
            "player fallback does not use a team crest"
        )
        expect(
            FanGeoPlayerAthleteFallbackMarkMetrics.personFontSize(diameter: 28) >= 11,
            "compact player fallback remains readable"
        )
        expect(
            FanGeoPlayerAthleteFallbackMarkMetrics.starFontSize(diameter: 28) >= 6,
            "compact star remains visible"
        )
        expect(
            FanGeoPlayerAthleteFallbackMarkMetrics.personFontSize(diameter: 118)
                > FanGeoPlayerAthleteFallbackMarkMetrics.personFontSize(diameter: 28),
            "large player fallback scales with the plate"
        )
        let userTeam = SportsIdentityArtworkResolver.resolveFanGeoUserTeam()
        expect(
            {
                if case .playerAthleteFallback = userTeam.kind { return false }
                return true
            }(),
            "FanGeo user/team fallback is not the athlete Person-with-Star mark"
        )
        expect(
            {
                if case .genericSymbol(let systemName, _) = userTeam.kind {
                    return systemName == "person.3.fill"
                }
                return false
            }(),
            "FanGeo user-created Team keeps the existing generic-symbol fallback"
        )
        expect(
            !SportsArtworkEnrichmentService.usesDirectTheSportsDBAPI,
            "player fallback does not call TheSportsDB from iOS"
        )
        let revisionBeforeFallback = SportsArtworkURLStore.shared.currentPublishedRevision()
        _ = SportsIdentityArtworkResolver.resolve(favoriteTeam: athlete)
        expect(
            SportsArtworkURLStore.shared.currentPublishedRevision() == revisionBeforeFallback,
            "Person-with-Star fallback does not write the artwork cache"
        )
        if let catalogAthlete = FavoriteTeamCatalog.team(id: "player-kylian-mbappe") {
            expect(
                catalogAthlete.kind == .player && catalogAthlete.sport == .soccer,
                "Kylian Mbappé is a Featured Athletes catalog identity"
            )
            let featured = SportsIdentityArtworkResolver.resolve(favoriteTeam: catalogAthlete)
            expect(
                {
                    if case .playerAthleteFallback = featured.kind { return true }
                    return false
                }(),
                "Featured Athletes cards use Person-with-Star when no photo exists"
            )
        } else {
            expect(false, "Kylian Mbappé catalog identity exists")
        }
        expect(
            FanGeoPlayerAthleteFallbackMarkMetrics.personFontSize(diameter: 28) < 28,
            "compact person glyph fits the plate"
        )
        expect(
            FanGeoPlayerAthleteFallbackMarkMetrics.starFontSize(diameter: 118) < 118,
            "large star glyph fits the plate"
        )

        SportsArtworkURLStore.shared.ingestPlayer(playerName: "Kylian Mbappé", imageURL: mbappeCutout)
        let athleteWithPhoto = SportsIdentityArtworkResolver.resolve(favoriteTeam: athlete)
        expect(
            {
                if case .verifiedRemote(let url) = athleteWithPhoto.kind {
                    return url.absoluteString.localizedCaseInsensitiveContains("mbappe")
                }
                return false
            }(),
            "real player artwork wins over Person-with-Star"
        )

        if failures == 0 {
            print("[SportsIdentityArtworkTest] ALL PASSED")
        } else {
            print("[SportsIdentityArtworkTest] FAILURES=\(failures)")
            assertionFailure("SportsIdentityArtworkSelfTests failed: \(failures)")
        }
    }
}
#endif
