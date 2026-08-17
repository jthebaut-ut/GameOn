// Canonical TheSportsDB league-team lookup.
// Official contracts:
//   V2 (premium): GET /api/v2/json/list/teams/{idLeague}  header X-API-KEY
//                 JSON top-level key is `list` (see /api/v2/examples/list_league_teams.json)
//   V1: GET /api/v1/json/{key}/search_all_teams.php?id={idLeague}
//       (also ?l={leagueName})  JSON top-level key is `teams`
// Do NOT use lookup_all_teams.php?id= — that endpoint ignores the league id
// and dumps English League 1 (Wigan/Blackpool/…) for 4387 and 4328 alike.

export type LeagueConfig = {
  id: string
  sport: string
  league: string
  kind: "team" | "national_team"
}

export type ProviderTeam = {
  idTeam: string
  strTeam: string
  strLeague: string
  strSport: string
  strBadge: string | null
  strLogo: string | null
  strCountry: string | null
}

export type TeamLookupEndpoint =
  | "v2_list_teams"
  | "v1_search_all_teams_id"
  | "v1_search_all_teams_l"
  | "none"

export type LeagueTeamLookupDiagnostics = {
  leagueId: string
  leagueName: string
  endpoint: TeamLookupEndpoint
  httpStatus: number | null
  contentType: string | null
  topLevelKeys: string[]
  teamCount: number
  providerMessage: string | null
}

export type LeagueTeamLookupResult = {
  teams: ProviderTeam[]
  diagnostics: LeagueTeamLookupDiagnostics
  requestCount: number
}

const THESPORTSDB_V2_BASE = "https://www.thesportsdb.com/api/v2/json"
const THESPORTSDB_V1_BASE = "https://www.thesportsdb.com/api/v1/json"

export function cleanString(value: unknown): string | null {
  if (typeof value !== "string") return null
  const trimmed = value.trim()
  return trimmed.length > 0 ? trimmed : null
}

export function redactedTheSportsDBURL(url: string): string {
  return url
    .replace(/\/api\/v1\/json\/[^/]+\//, "/api/v1/json/redacted/")
    .replace(/([?&](?:api[_-]?key|apikey)=)[^&]+/gi, "$1redacted")
}

export function topLevelJSONKeys(data: unknown): string[] {
  if (!data || typeof data !== "object" || Array.isArray(data)) return []
  return Object.keys(data as Record<string, unknown>)
}

export function providerErrorMessage(data: unknown): string | null {
  if (!data || typeof data !== "object" || Array.isArray(data)) return null
  const record = data as Record<string, unknown>
  for (const key of ["Message", "message", "error", "Error"]) {
    const value = cleanString(record[key])
    if (value) return value
  }
  return null
}

/** Official V2 example uses `list`; V1 uses `teams`. Accept both. */
export function extractProviderTeamRows(data: unknown): unknown[] {
  if (!data || typeof data !== "object" || Array.isArray(data)) return []
  const record = data as Record<string, unknown>
  for (const key of ["list", "teams", "team"]) {
    const value = record[key]
    if (Array.isArray(value)) return value
  }
  return []
}

export function mapProviderTeamRows(
  rows: unknown[],
  league: LeagueConfig,
  allowedArtworkURL: (raw: string | null) => string | null,
): ProviderTeam[] {
  const teams: ProviderTeam[] = []
  for (const row of rows) {
    if (!row || typeof row !== "object") continue
    const record = row as Record<string, unknown>
    const idTeam = cleanString(record.idTeam)
    const strTeam = cleanString(record.strTeam)
    if (!idTeam || !strTeam) continue
    teams.push({
      idTeam,
      strTeam,
      strLeague: cleanString(record.strLeague) ?? league.league,
      strSport: cleanString(record.strSport) ?? league.sport,
      strBadge: allowedArtworkURL(cleanString(record.strBadge)),
      strLogo: allowedArtworkURL(cleanString(record.strLogo)),
      strCountry: cleanString(record.strCountry),
    })
  }
  return teams
}

function emptyDiagnostics(league: LeagueConfig): LeagueTeamLookupDiagnostics {
  return {
    leagueId: league.id,
    leagueName: league.league,
    endpoint: "none",
    httpStatus: null,
    contentType: null,
    topLevelKeys: [],
    teamCount: 0,
    providerMessage: null,
  }
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

export async function fetchLeagueTeams(
  apiKey: string,
  league: LeagueConfig,
  allowedArtworkURL: (raw: string | null) => string | null,
  log: (message: string) => void = console.log,
): Promise<LeagueTeamLookupResult> {
  let requestCount = 0
  const diagnostics = emptyDiagnostics(league)

  const applyAttempt = (
    endpoint: Exclude<TeamLookupEndpoint, "none">,
    attempt: { status: number; contentType: string | null; data: unknown },
    teams: ProviderTeam[],
  ) => {
    diagnostics.endpoint = endpoint
    diagnostics.httpStatus = attempt.status
    diagnostics.contentType = attempt.contentType
    diagnostics.topLevelKeys = topLevelJSONKeys(attempt.data)
    diagnostics.teamCount = teams.length
    diagnostics.providerMessage = providerErrorMessage(attempt.data)
  }

  const v2URL = `${THESPORTSDB_V2_BASE}/list/teams/${encodeURIComponent(league.id)}`
  log(`request v2_list_teams league=${league.id} url=${v2URL}`)
  const v2 = await fetchJSON(v2URL, { "X-API-KEY": apiKey })
  requestCount += 1
  const v2Teams = mapProviderTeamRows(
    extractProviderTeamRows(v2.data),
    league,
    allowedArtworkURL,
  )
  applyAttempt("v2_list_teams", v2, v2Teams)
  if (v2Teams.length > 0) {
    return { teams: v2Teams, diagnostics, requestCount }
  }
  log(
    `v2_list_teams empty league=${league.id} status=${v2.status} keys=${diagnostics.topLevelKeys.join(",") || "-"} message=${diagnostics.providerMessage ?? "-"}`,
  )

  const v1IdURL =
    `${THESPORTSDB_V1_BASE}/${apiKey}/search_all_teams.php?id=${encodeURIComponent(league.id)}`
  log(`request v1_search_all_teams_id league=${league.id} url=${redactedTheSportsDBURL(v1IdURL)}`)
  const v1Id = await fetchJSON(v1IdURL)
  requestCount += 1
  const v1IdTeams = mapProviderTeamRows(
    extractProviderTeamRows(v1Id.data),
    league,
    allowedArtworkURL,
  )
  applyAttempt("v1_search_all_teams_id", v1Id, v1IdTeams)
  if (v1IdTeams.length > 0) {
    return { teams: v1IdTeams, diagnostics, requestCount }
  }
  log(
    `v1_search_all_teams_id empty league=${league.id} status=${v1Id.status} keys=${topLevelJSONKeys(v1Id.data).join(",") || "-"} message=${providerErrorMessage(v1Id.data) ?? "-"}`,
  )

  const leagueQuery = league.league.replace(/\s+/g, "_")
  const v1NameURL =
    `${THESPORTSDB_V1_BASE}/${apiKey}/search_all_teams.php?l=${encodeURIComponent(leagueQuery)}`
  log(`request v1_search_all_teams_l league=${league.id} url=${redactedTheSportsDBURL(v1NameURL)}`)
  const v1Name = await fetchJSON(v1NameURL)
  requestCount += 1
  const v1NameTeams = mapProviderTeamRows(
    extractProviderTeamRows(v1Name.data),
    league,
    allowedArtworkURL,
  )
  applyAttempt("v1_search_all_teams_l", v1Name, v1NameTeams)
  if (v1NameTeams.length === 0) {
    diagnostics.endpoint = "none"
  }
  return { teams: v1NameTeams, diagnostics, requestCount }
}
