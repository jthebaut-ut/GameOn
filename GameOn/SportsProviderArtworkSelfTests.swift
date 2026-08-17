import Foundation

#if DEBUG
enum SportsProviderArtworkSelfTests {
    static func runAll() {
        var failures = 0
        func expect(_ condition: Bool, _ name: String) {
            if condition {
                print("[SportsProviderArtworkTest] PASS \(name)")
            } else {
                failures += 1
                print("[SportsProviderArtworkTest] FAIL \(name)")
            }
        }

        let snapshot = SportsArtworkURLStore.shared.pushTestIsolation()
        defer { SportsArtworkURLStore.shared.popTestIsolation(snapshot) }

        expect(
            !SportsArtworkEnrichmentService.usesDirectTheSportsDBAPI,
            "no direct iOS TheSportsDB request"
        )

        let jazzURL = "https://www.thesportsdb.com/images/media/team/badge/jazz.png"
        let bullsURL = "https://www.thesportsdb.com/images/media/team/badge/bulls.png"
        let lakersURL = "https://www.thesportsdb.com/images/media/team/badge/lakers.png"
        let franceURL = "https://r2.thesportsdb.com/images/media/team/badge/france.png"
        let mbappeURL = "https://www.thesportsdb.com/images/media/player/cutout/mbappe.png"
        let psgURL = "https://www.thesportsdb.com/images/media/team/badge/psg.png"

        guard let jazz = FavoriteTeamCatalog.team(id: "basketball-team-jazz"),
              let bulls = FavoriteTeamCatalog.team(id: "nba-bulls"),
              let lakers = FavoriteTeamCatalog.team(id: "nba-lakers"),
              let france = FavoriteTeamCatalog.team(id: "soccer-france"),
              let mbappe = FavoriteTeamCatalog.team(id: "player-kylian-mbappe") else {
            print("[SportsProviderArtworkTest] FAIL required catalog identities exist")
            assertionFailure("SportsProviderArtworkSelfTests missing catalog identities")
            return
        }

        let missingJazz = SportsIdentityArtworkResolver.resolve(favoriteTeam: jazz)
        expect(
            {
                if case .fanGeoMonogram = missingJazz.kind { return true }
                return false
            }(),
            "missing provider mapping → initials fallback"
        )
        let missingMbappe = SportsIdentityArtworkResolver.resolve(favoriteTeam: mbappe)
        expect(
            {
                if case .playerAthleteFallback = missingMbappe.kind { return true }
                return false
            }(),
            "Featured Athlete without cutout uses Person-with-Star"
        )

        SportsProviderArtworkIngest.ingest([
            SportsProviderIdentityRow(
                catalogId: "basketball-team-jazz",
                kind: "team",
                provider: "thesportsdb",
                providerTeamId: "134875",
                providerPlayerId: nil,
                canonicalName: "Utah Jazz",
                league: "NBA",
                sport: "Basketball",
                country: "United States",
                badgeUrl: jazzURL,
                logoUrl: nil,
                playerCutoutUrl: nil,
                playerCreativeCommons: nil
            ),
            SportsProviderIdentityRow(
                catalogId: "nba-bulls",
                kind: "team",
                provider: "thesportsdb",
                providerTeamId: "134860",
                providerPlayerId: nil,
                canonicalName: "Chicago Bulls",
                league: "NBA",
                sport: "Basketball",
                country: "United States",
                badgeUrl: bullsURL,
                logoUrl: nil,
                playerCutoutUrl: nil,
                playerCreativeCommons: nil
            ),
            SportsProviderIdentityRow(
                catalogId: "nba-lakers",
                kind: "team",
                provider: "thesportsdb",
                providerTeamId: "134867",
                providerPlayerId: nil,
                canonicalName: "Los Angeles Lakers",
                league: "NBA",
                sport: "Basketball",
                country: "United States",
                badgeUrl: lakersURL,
                logoUrl: nil,
                playerCutoutUrl: nil,
                playerCreativeCommons: nil
            ),
            SportsProviderIdentityRow(
                catalogId: "soccer-france",
                kind: "national_team",
                provider: "thesportsdb",
                providerTeamId: "133957",
                providerPlayerId: nil,
                canonicalName: "France",
                league: "National Team",
                sport: "Soccer",
                country: "France",
                badgeUrl: franceURL,
                logoUrl: nil,
                playerCutoutUrl: nil,
                playerCreativeCommons: nil
            ),
            SportsProviderIdentityRow(
                catalogId: "player-kylian-mbappe",
                kind: "player",
                provider: "thesportsdb",
                providerTeamId: nil,
                providerPlayerId: "34145445",
                canonicalName: "Kylian Mbappe",
                league: "Soccer",
                sport: "Soccer",
                country: nil,
                badgeUrl: psgURL,
                logoUrl: nil,
                playerCutoutUrl: mbappeURL,
                playerCreativeCommons: true
            ),
            SportsProviderIdentityRow(
                catalogId: "player-blocked-cc",
                kind: "player",
                provider: "thesportsdb",
                providerTeamId: nil,
                providerPlayerId: "1",
                canonicalName: "Blocked Player",
                league: "Soccer",
                sport: "Soccer",
                country: nil,
                badgeUrl: nil,
                logoUrl: nil,
                playerCutoutUrl: mbappeURL,
                playerCreativeCommons: false
            ),
            SportsProviderIdentityRow(
                catalogId: "tournament-super-bowl",
                kind: "league",
                provider: "thesportsdb",
                providerTeamId: nil,
                providerPlayerId: nil,
                canonicalName: "Super Bowl",
                league: "Football Tournament",
                sport: "Football",
                country: "United States",
                badgeUrl: "https://r2.thesportsdb.com/images/media/league/badge/superbowl.png",
                logoUrl: nil,
                playerCutoutUrl: nil,
                playerCreativeCommons: nil
            ),
            SportsProviderIdentityRow(
                catalogId: "league-nfl",
                kind: "league",
                provider: "thesportsdb",
                providerTeamId: nil,
                providerPlayerId: nil,
                canonicalName: "NFL",
                league: "Football League",
                sport: "Football",
                country: "United States",
                badgeUrl: "https://r2.thesportsdb.com/images/media/league/badge/nfl.png",
                logoUrl: nil,
                playerCutoutUrl: nil,
                playerCreativeCommons: nil
            )
        ])

        let jazzArt = SportsIdentityArtworkResolver.resolve(favoriteTeam: jazz)
        let bullsArt = SportsIdentityArtworkResolver.resolve(favoriteTeam: bulls)
        let lakersArt = SportsIdentityArtworkResolver.resolve(favoriteTeam: lakers)
        let franceArt = SportsIdentityArtworkResolver.resolve(favoriteTeam: france)
        let mbappeArt = SportsIdentityArtworkResolver.resolve(favoriteTeam: mbappe)
        let pickerArt = SportsIdentityArtworkResolver.resolve(favoriteTeam: jazz)
        let cardArt = SportsIdentityArtworkResolver.resolveProGameTeam(
            teamName: "Los Angeles Lakers",
            badgeURL: nil,
            league: "NBA",
            source: "thesportsdb"
        )

        expect(
            {
                if case .verifiedRemote(let url) = jazzArt.kind {
                    return url.absoluteString.contains("jazz.png")
                }
                return false
            }(),
            "Utah Jazz badge from provider metadata without live_matches"
        )
        expect(
            {
                if case .verifiedRemote(let url) = bullsArt.kind {
                    return url.absoluteString.contains("bulls.png")
                }
                return false
            }(),
            "Chicago Bulls badge from provider metadata without live_matches"
        )
        expect(
            {
                if case .verifiedRemote(let url) = lakersArt.kind {
                    return url.absoluteString.contains("lakers.png")
                }
                return false
            }(),
            "Los Angeles Lakers badge from provider metadata"
        )
        expect(
            {
                if case .verifiedRemote(let url) = franceArt.kind {
                    return url.absoluteString.contains("france.png")
                }
                return false
            }(),
            "national team prefers provider crest over flag"
        )
        expect(
            {
                if case .verifiedRemote(let url) = mbappeArt.kind {
                    return url.absoluteString.contains("mbappe.png") && !url.absoluteString.contains("psg.png")
                }
                return false
            }(),
            "player uses cutout not club logo"
        )
        expect(
            SportsArtworkURLStore.shared.playerImageURL(playerName: "Blocked Player") == nil,
            "player without creative commons is not ingested"
        )
        expect(
            {
                if case .verifiedRemote(let url) = pickerArt.kind {
                    return url.absoluteString.contains("jazz.png")
                }
                return false
            }(),
            "Profile / picker Jazz identity shares provider artwork"
        )
        expect(
            {
                if case .verifiedRemote(let url) = cardArt.kind {
                    return url.absoluteString.contains("lakers.png")
                }
                return false
            }(),
            "Pro Games card can resolve Lakers from provider metadata"
        )

        if let superBowl = FavoriteTeamCatalog.team(id: "tournament-super-bowl") {
            let superBowlArt = SportsIdentityArtworkResolver.resolve(favoriteTeam: superBowl)
            expect(
                {
                    if case .verifiedRemote(let url) = superBowlArt.kind {
                        return url.absoluteString.contains("superbowl.png")
                    }
                    return false
                }(),
                "provider league row hydrates Super Bowl competition artwork"
            )
            expect(
                {
                    if case .verifiedRemote(let url) = superBowlArt.kind {
                        return !url.absoluteString.contains("lakers") && !url.absoluteString.contains("nfl.png")
                    }
                    return false
                }(),
                "Super Bowl does not use a club logo or the NFL shield"
            )
            expect(
                SportsIdentityArtworkResolver.resolve(favoriteTeam: lakers).kind != superBowlArt.kind
                    || {
                        if case .verifiedRemote(let url) = lakersArt.kind {
                            return !url.absoluteString.contains("superbowl")
                        }
                        return true
                    }(),
                "club artwork stays on the club identity"
            )
        } else {
            expect(false, "Super Bowl catalog identity exists")
        }

        let fanGeo = SportsIdentityArtworkResolver.resolveFanGeoUserTeam()
        expect(
            {
                if case .verifiedRemote = fanGeo.kind { return false }
                return true
            }(),
            "FanGeo user Team never uses professional artwork"
        )

        expect(
            SportsArtworkURLStore.shared.badgeURL(catalogId: "basketball-team-jazz") != nil,
            "catalog-id lookup is provider-ID-first after ingest"
        )

        SportsArtworkURLStore.shared.resetForTests()
        if let marchMadness = FavoriteTeamCatalog.team(id: "tournament-march-madness") {
            let fallback = SportsIdentityArtworkResolver.resolve(favoriteTeam: marchMadness)
            expect(
                {
                    if case .competitionFallback = fallback.kind { return true }
                    return false
                }(),
                "competition without provider artwork uses the FanGeo competition fallback"
            )
        }

        if failures == 0 {
            print("[SportsProviderArtworkTest] ALL PASSED")
        } else {
            print("[SportsProviderArtworkTest] FAILURES=\(failures)")
            assertionFailure("SportsProviderArtworkSelfTests failed: \(failures)")
        }
    }
}
#endif
