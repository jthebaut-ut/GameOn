/**
 * Roster player lookup checks. No live paid-key calls.
 *
 * Run:
 *   deno test supabase/functions/sync-sports-provider-artwork/provider-roster-lookup_self_test.ts
 */

import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts"
import {
  curatedPlayerCatalogId,
  displayLeagueName,
  isRetiredPlayerStatus,
  isRosterStaffPosition,
} from "./catalog-matcher.ts"
import {
  extractProviderPlayerRows,
  mapProviderPlayerRows,
} from "./provider-roster-lookup.ts"
import { redactedTheSportsDBURL as redactTeamURL } from "./provider-team-lookup.ts"

function passthroughArtwork(raw: string | null): string | null {
  return raw
}

Deno.test("V1 player payload is decoded from `player`", () => {
  const payload = {
    player: [
      {
        idPlayer: "34145445",
        strPlayer: "LeBron James",
        idTeam: "134867",
        strTeam: "Los Angeles Lakers",
        strSport: "Basketball",
        strPosition: "Forward",
        strCutout: "https://www.thesportsdb.com/images/media/player/cutout/lebron.png",
        strCreativeCommons: "Yes",
      },
      {
        idPlayer: "1",
        strPlayer: "JJ Redick",
        idTeam: "134867",
        strTeam: "Los Angeles Lakers",
        strPosition: "Manager",
      },
      {
        idPlayer: "2",
        strPlayer: "Historical Star",
        strStatus: "Retired",
      },
    ],
  }
  const rows = extractProviderPlayerRows(payload)
  const mapped = mapProviderPlayerRows(rows, "134867", "Los Angeles Lakers", passthroughArtwork)
  assertEquals(mapped.players.length, 1)
  assertEquals(mapped.players[0].strPlayer, "LeBron James")
  assertEquals(mapped.skippedStaff, 1)
  assertEquals(mapped.skippedRetired, 1)
})

Deno.test("V2 player payload is decoded from `list`", () => {
  const payload = {
    list: [
      {
        idPlayer: "34162727",
        strPlayer: "Lionel Messi",
        idTeam: "137839",
        strTeam: "Inter Miami",
        strSport: "Soccer",
        strPosition: "Forward",
      },
      {
        idPlayer: "34162727",
        strPlayer: "Lionel Messi",
        strPosition: "Forward",
      },
    ],
  }
  const mapped = mapProviderPlayerRows(
    extractProviderPlayerRows(payload),
    "137839",
    "Inter Miami",
    passthroughArtwork,
  )
  assertEquals(mapped.players.length, 1)
  assertEquals(mapped.players[0].idPlayer, "34162727")
})

Deno.test("staff and retired filters", () => {
  assert(isRosterStaffPosition("Manager"))
  assert(isRosterStaffPosition("Head Coach"))
  assert(!isRosterStaffPosition("Forward"))
  assert(!isRosterStaffPosition("Pitcher"))
  assert(isRetiredPlayerStatus("Retired"))
  assert(!isRetiredPlayerStatus("Active"))
})

Deno.test("curated player IDs win over generated roster IDs", () => {
  assertEquals(
    curatedPlayerCatalogId({ playerName: "LeBron James", sport: "Basketball" }),
    "player-lebron-james",
  )
  assertEquals(
    curatedPlayerCatalogId({ playerName: "Lionel Messi", sport: "Soccer" }),
    "player-lionel-messi",
  )
  assertEquals(
    curatedPlayerCatalogId({ playerName: "Unknown Rookie", sport: "Basketball" }),
    null,
  )
})

Deno.test("league display names stay FanGeo-friendly", () => {
  assertEquals(displayLeagueName("English Premier League"), "Premier League")
  assertEquals(displayLeagueName("Spanish La Liga"), "La Liga")
  assertEquals(displayLeagueName("NBA"), "NBA")
})

Deno.test("roster URLs redact the API key", () => {
  const raw = "https://www.thesportsdb.com/api/v1/json/SECRETKEY/lookup_all_players.php?id=134867"
  const redacted = redactTeamURL(raw)
  assert(!redacted.includes("SECRETKEY"))
  assert(redacted.includes("lookup_all_players.php"))
})
