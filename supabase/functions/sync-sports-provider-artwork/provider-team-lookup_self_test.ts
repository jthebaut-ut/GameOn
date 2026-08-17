/**
 * Provider team-list lookup checks.
 *
 * Run:
 *   deno test --allow-net supabase/functions/sync-sports-provider-artwork/catalog-matcher_self_test.ts
 *   deno test --allow-net supabase/functions/sync-sports-provider-artwork/provider-team-lookup_self_test.ts
 *
 * Live league-list checks use TheSportsDB public test key `123` (not the paid key).
 * V2 list/teams requires X-API-KEY; with `123` it 400s and the worker falls back to
 * V1 search_all_teams.php, which is free-capped at 10 teams.
 */

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts"
import { assert } from "https://deno.land/std@0.224.0/assert/mod.ts"
import { matchCatalogIdentities } from "./catalog-matcher.ts"
import {
  extractProviderTeamRows,
  fetchLeagueTeams,
  mapProviderTeamRows,
  providerErrorMessage,
  redactedTheSportsDBURL,
  topLevelJSONKeys,
  type LeagueConfig,
  type ProviderTeam,
} from "./provider-team-lookup.ts"

const NBA: LeagueConfig = { id: "4387", sport: "Basketball", league: "NBA", kind: "team" }
const WNBA: LeagueConfig = { id: "4516", sport: "Basketball", league: "WNBA", kind: "team" }
const NFL: LeagueConfig = { id: "4391", sport: "American Football", league: "NFL", kind: "team" }
const MLB: LeagueConfig = { id: "4424", sport: "Baseball", league: "MLB", kind: "team" }
const NHL: LeagueConfig = { id: "4380", sport: "Ice Hockey", league: "NHL", kind: "team" }
const EPL: LeagueConfig = {
  id: "4328",
  sport: "Soccer",
  league: "English Premier League",
  kind: "team",
}

const PUBLIC_TEST_KEY = "123"

function passthroughArtwork(raw: string | null): string | null {
  return raw
}

function names(teams: ProviderTeam[]): string[] {
  return teams.map((team) => team.strTeam)
}

function catalogIdsFor(team: ProviderTeam, league: LeagueConfig): string[] {
  return matchCatalogIdentities({
    teamName: team.strTeam,
    league: team.strLeague,
    sport: team.strSport,
    kind: league.kind,
  }).map((row) => row.catalogId)
}

Deno.test("V2 list payload is decoded from `list`, not only `teams`", () => {
  const payload = {
    list: [
      {
        idTeam: "134875",
        strTeam: "Utah Jazz",
        strLeague: "NBA",
        strBadge: "https://r2.thesportsdb.com/images/media/team/badge/jazz.png",
        strLogo: "https://r2.thesportsdb.com/images/media/team/logo/jazz.png",
        strCountry: "USA",
      },
      {
        idTeam: "134860",
        strTeam: "Chicago Bulls",
        strLeague: "NBA",
        strBadge: "https://r2.thesportsdb.com/images/media/team/badge/bulls.png",
        strLogo: null,
        strCountry: "USA",
      },
      {
        idTeam: "134867",
        strTeam: "Los Angeles Lakers",
        strLeague: "NBA",
        strBadge: "https://r2.thesportsdb.com/images/media/team/badge/lakers.png",
        strLogo: "https://r2.thesportsdb.com/images/media/team/logo/lakers.png",
        strCountry: "USA",
      },
    ],
  }
  assertEquals(topLevelJSONKeys(payload), ["list"])
  const rows = extractProviderTeamRows(payload)
  assertEquals(rows.length, 3)
  const teams = mapProviderTeamRows(rows, NBA, passthroughArtwork)
  assertEquals(names(teams).sort(), ["Chicago Bulls", "Los Angeles Lakers", "Utah Jazz"])
  const matched = teams.flatMap((team) => catalogIdsFor(team, NBA))
  assert(matched.includes("basketball-team-jazz"))
  assert(matched.includes("nba-bulls"))
  assert(matched.includes("basketball-team-bulls"))
  assert(matched.includes("nba-lakers"))
  assert(matched.includes("basketball-team-lakers"))
})

Deno.test("V1 teams payload is still decoded", () => {
  const payload = {
    teams: [
      { idTeam: "134860", strTeam: "Chicago Bulls", strLeague: "NBA", strSport: "Basketball" },
    ],
  }
  const teams = mapProviderTeamRows(extractProviderTeamRows(payload), NBA, passthroughArtwork)
  assertEquals(teams.length, 1)
  assertEquals(teams[0].strTeam, "Chicago Bulls")
})

Deno.test("null teams / provider Message yields zero teams", () => {
  assertEquals(extractProviderTeamRows({ teams: null }).length, 0)
  assertEquals(extractProviderTeamRows({ list: null }).length, 0)
  assertEquals(
    providerErrorMessage({ Message: "Missing API key in header, sign up at https://www.thesportsdb.com/pricing" }),
    "Missing API key in header, sign up at https://www.thesportsdb.com/pricing",
  )
})

Deno.test("legacy lookup_all_teams League 1 dump is not NBA", () => {
  const payload = {
    teams: [
      { idTeam: "133601", strTeam: "Wigan Athletic", strLeague: "English League 1", strSport: "Soccer" },
      { idTeam: "133602", strTeam: "Blackpool", strLeague: "English League 1", strSport: "Soccer" },
    ],
  }
  const teams = mapProviderTeamRows(extractProviderTeamRows(payload), NBA, passthroughArtwork)
  assertEquals(teams.every((team) => team.strLeague === "English League 1"), true)
  assertEquals(names(teams).includes("Utah Jazz"), false)
  assertEquals(names(teams).includes("Chicago Bulls"), false)
  assertEquals(names(teams).includes("Los Angeles Lakers"), false)
})

Deno.test("API keys are redacted from V1 URLs", () => {
  const url = "https://www.thesportsdb.com/api/v1/json/super-secret-key/search_all_teams.php?id=4387"
  const redacted = redactedTheSportsDBURL(url)
  assertEquals(redacted.includes("super-secret-key"), false)
  assertEquals(redacted.includes("/redacted/"), true)
})

Deno.test({
  name: "live NBA 4387 lookup returns NBA teams including Bulls",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const result = await fetchLeagueTeams(PUBLIC_TEST_KEY, NBA, passthroughArtwork, () => {})
    assert(result.diagnostics.httpStatus === 200 || result.diagnostics.httpStatus === 400)
    assert(result.teams.length > 0, `expected NBA teams, got ${result.teams.length} endpoint=${result.diagnostics.endpoint}`)
    assertEquals(result.teams.every((team) => team.strLeague === "NBA"), true)
    assert(names(result.teams).includes("Chicago Bulls"))
    const matched = result.teams.flatMap((team) => catalogIdsFor(team, NBA))
    assert(matched.includes("nba-bulls"))
  },
})

Deno.test({
  name: "live searchteams confirms Jazz/Bulls/Lakers belong to NBA 4387",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const wanted = ["Utah Jazz", "Chicago Bulls", "Los Angeles Lakers"]
    for (const name of wanted) {
      const url =
        `https://www.thesportsdb.com/api/v1/json/${PUBLIC_TEST_KEY}/searchteams.php?t=${encodeURIComponent(name)}`
      const response = await fetch(url)
      assertEquals(response.status, 200)
      const data = await response.json() as { teams?: Array<{ strTeam?: string; idLeague?: string; strLeague?: string }> }
      const row = (data.teams ?? [])[0]
      assertEquals(row?.strTeam, name)
      assertEquals(row?.idLeague, "4387")
      assertEquals(row?.strLeague, "NBA")
    }
  },
})

Deno.test({
  name: "live MLB/NFL/NHL/EPL/WNBA lookups return provider teams",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const cases: Array<{ league: LeagueConfig; expectedLeague: string; sample: string }> = [
      { league: MLB, expectedLeague: "MLB", sample: "Atlanta Braves" },
      { league: NFL, expectedLeague: "NFL", sample: "Buffalo Bills" },
      { league: NHL, expectedLeague: "NHL", sample: "Boston Bruins" },
      { league: EPL, expectedLeague: "English Premier League", sample: "Arsenal" },
      { league: WNBA, expectedLeague: "WNBA", sample: "Chicago Sky" },
    ]
    for (const item of cases) {
      const result = await fetchLeagueTeams(PUBLIC_TEST_KEY, item.league, passthroughArtwork, () => {})
      assert(
        result.teams.length > 0,
        `${item.league.league} expected teams, got 0 endpoint=${result.diagnostics.endpoint} status=${result.diagnostics.httpStatus}`,
      )
      assertEquals(
        result.teams.every((team) => team.strLeague === item.expectedLeague),
        true,
        `${item.league.league} unexpected leagues: ${[...new Set(result.teams.map((team) => team.strLeague))].join(",")}`,
      )
      assert(
        names(result.teams).includes(item.sample),
        `${item.league.league} missing ${item.sample}; got ${names(result.teams).join(", ")}`,
      )
      const matched = result.teams.flatMap((team) => catalogIdsFor(team, item.league))
      if (item.league.id !== "4380") {
        assert(matched.length > 0, `${item.league.league} produced teams but zero catalog matches`)
      }
    }
  },
})
