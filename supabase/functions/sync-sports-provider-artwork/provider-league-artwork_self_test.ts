/**
 * Local league/competition artwork checks (no network, no API key).
 *
 * Run:
 *   deno test supabase/functions/sync-sports-provider-artwork/provider-league-artwork_self_test.ts
 */

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts"
import { CATALOG_IDENTITIES } from "./catalog-identities.ts"
import {
  CATALOG_LEAGUE_PROVIDER_IDS,
  compactCompetitionArtwork,
  competitionArtworkTargets,
  extractProviderLeagueRows,
  isCompactCompetitionArtworkURL,
  mapProviderLeagueArtwork,
  resolveCatalogLeagueProviderId,
} from "./provider-league-artwork.ts"

Deno.test("compact competition artwork prefers league badge over poster/trophy", () => {
  const badge = "https://r2.thesportsdb.com/images/media/league/badge/nfl.png"
  const logo = "https://r2.thesportsdb.com/images/media/league/logo/nfl.png"
  const poster = "https://r2.thesportsdb.com/images/media/league/poster/nfl.jpg"
  const trophy = "https://r2.thesportsdb.com/images/media/league/trophy/lombardi.png"
  assertEquals(isCompactCompetitionArtworkURL(badge), true)
  assertEquals(isCompactCompetitionArtworkURL(logo), true)
  assertEquals(isCompactCompetitionArtworkURL(poster), false)
  assertEquals(isCompactCompetitionArtworkURL(trophy), false)
  assertEquals(
    isCompactCompetitionArtworkURL("https://r2.thesportsdb.com/images/media/event/badge/sb-lx.png"),
    false,
  )
  const compact = compactCompetitionArtwork(badge, logo)
  assertEquals(compact.url, badge)
  assertEquals(compact.usedLogoFallback, false)
  const logoOnly = compactCompetitionArtwork(poster, logo)
  assertEquals(logoOnly.url, logo)
  assertEquals(logoOnly.usedLogoFallback, true)
  const rejected = compactCompetitionArtwork("https://example.com/superbowl.png", trophy)
  assertEquals(rejected.url, null)
  assertEquals(rejected.rejectedUntrustedURLs > 0, true)
})

Deno.test("Super Bowl has no provider league ID and is not bound to NFL or poker", () => {
  const superBowl = CATALOG_IDENTITIES.find((row) => row.catalogId === "tournament-super-bowl")
  assertEquals(superBowl?.name, "Super Bowl")
  assertEquals(CATALOG_LEAGUE_PROVIDER_IDS["tournament-super-bowl"], undefined)
  const providerId = resolveCatalogLeagueProviderId(superBowl!, [
    { id: "4391", league: "NFL" },
    { id: "5457", league: "Super Bowl of Poker" },
  ])
  assertEquals(providerId, null)
  const targets = competitionArtworkTargets([
    { id: "4391", league: "NFL" },
    { id: "5457", league: "Super Bowl of Poker" },
  ])
  const row = targets.find((item) => item.catalogId === "tournament-super-bowl")
  assertEquals(row?.providerLeagueId, null)
})

Deno.test("NFL and Champions League resolve to competition-level provider IDs", () => {
  const nfl = CATALOG_IDENTITIES.find((row) => row.catalogId === "league-nfl")!
  const ucl = CATALOG_IDENTITIES.find((row) => row.catalogId === "tournament-champions-league")!
  assertEquals(
    resolveCatalogLeagueProviderId(nfl, [{ id: "4391", league: "NFL" }]),
    "4391",
  )
  assertEquals(resolveCatalogLeagueProviderId(ucl, []), "4480")
})

Deno.test("lookupleague payload maps badge and logo without using team crests", () => {
  const mapped = mapProviderLeagueArtwork(
    extractProviderLeagueRows({
      leagues: [{
        idLeague: "4480",
        strLeague: "UEFA Champions League",
        strSport: "Soccer",
        strBadge: "https://r2.thesportsdb.com/images/media/league/badge/ucl.png",
        strLogo: "https://r2.thesportsdb.com/images/media/league/logo/ucl.png",
        strPoster: "https://r2.thesportsdb.com/images/media/league/poster/ucl.jpg",
      }],
    }),
    (raw) => raw,
  )
  assertEquals(mapped?.idLeague, "4480")
  assertEquals(mapped?.strBadge?.includes("/league/badge/"), true)
  const compact = compactCompetitionArtwork(mapped?.strBadge, mapped?.strLogo)
  assertEquals(compact.url?.includes("/league/badge/"), true)
})
