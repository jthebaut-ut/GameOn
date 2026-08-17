/**
 * Local matcher checks (no network, no API key).
 *
 * Run:
 *   deno test supabase/functions/sync-sports-provider-artwork/catalog-matcher_self_test.ts
 */

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts"
import {
  catalogPlayers,
  isStableCompetitionCatalogId,
  isTheSportsDBArtworkURL,
  matchCatalogIdentities,
  matchCatalogLeagueIdentity,
  playerAllowsCreativeCommons,
} from "./catalog-matcher.ts"

Deno.test("Utah Jazz matches basketball-team-jazz year-round identity", () => {
  const matches = matchCatalogIdentities({
    teamName: "Utah Jazz",
    league: "NBA",
    sport: "Basketball",
    kind: "team",
  })
  const ids = matches.map((row) => row.catalogId)
  assertEquals(ids.includes("basketball-team-jazz"), true)
})

Deno.test("Chicago Bulls matches nba-bulls and picker identity", () => {
  const matches = matchCatalogIdentities({
    teamName: "Chicago Bulls",
    league: "NBA",
    sport: "Basketball",
    kind: "team",
  })
  const ids = matches.map((row) => row.catalogId)
  assertEquals(ids.includes("nba-bulls"), true)
  assertEquals(ids.includes("basketball-team-bulls"), true)
})

Deno.test("Los Angeles Lakers matches curated and picker identities", () => {
  const matches = matchCatalogIdentities({
    teamName: "Los Angeles Lakers",
    league: "NBA",
    sport: "Basketball",
    kind: "team",
  })
  const ids = matches.map((row) => row.catalogId)
  assertEquals(ids.includes("nba-lakers"), true)
  assertEquals(ids.includes("basketball-team-lakers"), true)
})

Deno.test("France soccer national team does not take basketball France", () => {
  const matches = matchCatalogIdentities({
    teamName: "France",
    league: "FIFA World Cup",
    sport: "Soccer",
    kind: "national_team",
  })
  const ids = matches.map((row) => row.catalogId)
  assertEquals(ids.includes("soccer-france"), true)
  assertEquals(ids.includes("bball-nt-france"), false)
})

Deno.test("unknown provider team yields no catalog mapping", () => {
  const matches = matchCatalogIdentities({
    teamName: "Unknown Athletic Club 2099",
    league: "NBA",
    sport: "Basketball",
    kind: "team",
  })
  assertEquals(matches.length, 0)
})

Deno.test("TheSportsDB badge hosts are accepted and others rejected", () => {
  assertEquals(
    isTheSportsDBArtworkURL("https://www.thesportsdb.com/images/media/team/badge/jazz.png"),
    true,
  )
  assertEquals(
    isTheSportsDBArtworkURL("https://r2.thesportsdb.com/images/media/team/badge/france.png"),
    true,
  )
  assertEquals(isTheSportsDBArtworkURL("https://example.com/jazz.png"), false)
  assertEquals(isTheSportsDBArtworkURL(""), false)
})

Deno.test("player creative commons is fail-closed", () => {
  assertEquals(playerAllowsCreativeCommons("Yes"), true)
  assertEquals(playerAllowsCreativeCommons("yes"), true)
  assertEquals(playerAllowsCreativeCommons(""), false)
  assertEquals(playerAllowsCreativeCommons("No"), false)
})

Deno.test("Chicago Bulls does not steal Lakers or Celtics identities", () => {
  const matches = matchCatalogIdentities({
    teamName: "Chicago Bulls",
    league: "NBA",
    sport: "Basketball",
    kind: "team",
  })
  const ids = matches.map((row) => row.catalogId)
  assertEquals(ids.includes("nba-lakers"), false)
  assertEquals(ids.includes("nba-celtics"), false)
  assertEquals(ids.includes("nba-warriors"), false)
  assertEquals(ids.includes("nba-bulls"), true)
})

Deno.test("Los Angeles Lakers does not steal Bulls identity", () => {
  const matches = matchCatalogIdentities({
    teamName: "Los Angeles Lakers",
    league: "NBA",
    sport: "Basketball",
    kind: "team",
  })
  const ids = matches.map((row) => row.catalogId)
  assertEquals(ids.includes("nba-bulls"), false)
  assertEquals(ids.includes("nba-lakers"), true)
})

Deno.test("featured players include Mbappé", () => {
  const ids = catalogPlayers().map((row) => row.catalogId)
  assertEquals(ids.includes("player-kylian-mbappe"), true)
})

Deno.test("Super Bowl is a stable competition identity, not a year-specific event", () => {
  const match = matchCatalogLeagueIdentity({
    leagueName: "Super Bowl",
    sport: "Football",
  })
  assertEquals(match?.catalogId, "tournament-super-bowl")
  assertEquals(isStableCompetitionCatalogId("tournament-super-bowl"), true)
  assertEquals(isStableCompetitionCatalogId("event-tsdb-2269999"), false)
  assertEquals(isStableCompetitionCatalogId("tournament-super-bowl-lx"), false)
})

Deno.test("Super Bowl of Poker does not match Super Bowl", () => {
  const match = matchCatalogLeagueIdentity({
    leagueName: "Super Bowl of Poker",
    sport: "Gambling",
  })
  assertEquals(match, null)
})

Deno.test("UEFA Champions League matches the stable Champions League identity", () => {
  const match = matchCatalogLeagueIdentity({
    leagueName: "UEFA Champions League",
    sport: "Soccer",
  })
  assertEquals(match?.catalogId, "tournament-champions-league")
})
