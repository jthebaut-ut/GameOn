// Canonical TheSportsDB team-roster lookup.
// Official contracts:
//   V1: GET /api/v1/json/{key}/lookup_all_players.php?id={idTeam}
//       JSON top-level key is `player`
//   V2 (premium): GET /api/v2/json/list/players/{idTeam}  header X-API-KEY
//                 JSON top-level key is `list`
// One request per team — never searchplayers.php per athlete.

import {
  isRetiredPlayerStatus,
  isRosterStaffPosition,
  playerAllowsCreativeCommons,
} from "./catalog-matcher.ts"
import {
  cleanString,
  providerErrorMessage,
  redactedTheSportsDBURL,
  topLevelJSONKeys,
} from "./provider-team-lookup.ts"

export type ProviderRosterPlayer = {
  idPlayer: string
  strPlayer: string
  idTeam: string | null
  strTeam: string | null
  strSport: string | null
  strPosition: string | null
  strStatus: string | null
  strCutout: string | null
  strThumb: string | null
  strCreativeCommons: string | null
  strNationality: string | null
}

export type RosterLookupEndpoint = "v2_list_players" | "v1_lookup_all_players" | "none"

export type RosterLookupDiagnostics = {
  teamId: string
  teamName: string
  endpoint: RosterLookupEndpoint
  httpStatus: number | null
  topLevelKeys: string[]
  playerCount: number
  skippedStaff: number
  skippedRetired: number
  providerMessage: string | null
}

export type RosterLookupResult = {
  players: ProviderRosterPlayer[]
  diagnostics: RosterLookupDiagnostics
  requestCount: number
}

const THESPORTSDB_V2_BASE = "https://www.thesportsdb.com/api/v2/json"
const THESPORTSDB_V1_BASE = "https://www.thesportsdb.com/api/v1/json"

export function extractProviderPlayerRows(data: unknown): unknown[] {
  if (!data || typeof data !== "object" || Array.isArray(data)) return []
  const record = data as Record<string, unknown>
  for (const key of ["list", "player", "players"]) {
    const value = record[key]
    if (Array.isArray(value)) return value
  }
  return []
}

export function mapProviderPlayerRows(
  rows: unknown[],
  teamId: string,
  teamName: string,
  allowedArtworkURL: (raw: string | null) => string | null,
): { players: ProviderRosterPlayer[]; skippedStaff: number; skippedRetired: number } {
  const players: ProviderRosterPlayer[] = []
  let skippedStaff = 0
  let skippedRetired = 0
  const seen = new Set<string>()
  for (const row of rows) {
    if (!row || typeof row !== "object") continue
    const record = row as Record<string, unknown>
    const idPlayer = cleanString(record.idPlayer)
    const strPlayer = cleanString(record.strPlayer)
    if (!idPlayer || !strPlayer) continue
    if (seen.has(idPlayer)) continue
    seen.add(idPlayer)
    const position = cleanString(record.strPosition) ?? cleanString(record.strRole)
    if (isRosterStaffPosition(position)) {
      skippedStaff += 1
      continue
    }
    const status = cleanString(record.strStatus)
    if (isRetiredPlayerStatus(status)) {
      skippedRetired += 1
      continue
    }
    players.push({
      idPlayer,
      strPlayer,
      idTeam: cleanString(record.idTeam) ?? teamId,
      strTeam: cleanString(record.strTeam) ?? teamName,
      strSport: cleanString(record.strSport),
      strPosition: position,
      strStatus: status,
      strCutout: allowedArtworkURL(cleanString(record.strCutout)),
      strThumb: allowedArtworkURL(cleanString(record.strThumb)),
      strCreativeCommons: cleanString(record.strCreativeCommons),
      strNationality: cleanString(record.strNationality),
    })
  }
  return { players, skippedStaff, skippedRetired }
}

export function rosterPlayerAllowsArtwork(player: ProviderRosterPlayer): boolean {
  return playerAllowsCreativeCommons(player.strCreativeCommons)
}

async function fetchJSON(
  url: string,
  headers?: HeadersInit,
): Promise<{ status: number; contentType: string | null; data: unknown }> {
  const response = await fetch(url, { headers })
  const contentType = response.headers.get("content-type")
  let data: unknown = null
  try {
    data = await response.json()
  } catch {
    data = null
  }
  return { status: response.status, contentType, data }
}

export async function fetchTeamRoster(
  apiKey: string,
  teamId: string,
  teamName: string,
  allowedArtworkURL: (raw: string | null) => string | null,
  log: (message: string) => void = console.log,
): Promise<RosterLookupResult> {
  const empty: RosterLookupDiagnostics = {
    teamId,
    teamName,
    endpoint: "none",
    httpStatus: null,
    topLevelKeys: [],
    playerCount: 0,
    skippedStaff: 0,
    skippedRetired: 0,
    providerMessage: null,
  }
  if (!teamId.trim()) {
    return { players: [], diagnostics: empty, requestCount: 0 }
  }

  let requestCount = 0
  const v2URL = `${THESPORTSDB_V2_BASE}/list/players/${encodeURIComponent(teamId)}`
  log(`request ${redactedTheSportsDBURL(v2URL)}`)
  const v2 = await fetchJSON(v2URL, { "X-API-KEY": apiKey })
  requestCount += 1
  let rows = extractProviderPlayerRows(v2.data)
  let endpoint: RosterLookupEndpoint = "v2_list_players"
  let httpStatus = v2.status
  let topKeys = topLevelJSONKeys(v2.data)
  let message = providerErrorMessage(v2.data)

  if (rows.length === 0) {
    const v1URL =
      `${THESPORTSDB_V1_BASE}/${apiKey}/lookup_all_players.php?id=${encodeURIComponent(teamId)}`
    log(`request ${redactedTheSportsDBURL(v1URL)}`)
    const v1 = await fetchJSON(v1URL)
    requestCount += 1
    rows = extractProviderPlayerRows(v1.data)
    endpoint = "v1_lookup_all_players"
    httpStatus = v1.status
    topKeys = topLevelJSONKeys(v1.data)
    message = providerErrorMessage(v1.data)
  }

  const mapped = mapProviderPlayerRows(rows, teamId, teamName, allowedArtworkURL)
  return {
    players: mapped.players,
    requestCount,
    diagnostics: {
      teamId,
      teamName,
      endpoint,
      httpStatus,
      topLevelKeys: topKeys,
      playerCount: mapped.players.length,
      skippedStaff: mapped.skippedStaff,
      skippedRetired: mapped.skippedRetired,
      providerMessage: message,
    },
  }
}
