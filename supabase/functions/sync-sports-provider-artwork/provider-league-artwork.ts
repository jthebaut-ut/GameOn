// Canonical TheSportsDB league/competition artwork lookup.
// Official contracts:
//   V2 (premium): GET /api/v2/json/lookup/league/{idLeague}  header X-API-KEY
//   V1: GET /api/v1/json/{key}/lookupleague.php?id={idLeague}
// Compact identity cards use league badge, then league logo.
// Never ingest posters, banners, fanart, trophy photos, or year-specific event art
// onto a stable competition identity (e.g. Super Bowl, not Super Bowl LX).

import {
  catalogLeagues,
  isExactLeagueNameMatch,
  isStableCompetitionCatalogId,
  isTheSportsDBArtworkURL,
  type SportsCatalogIdentity,
} from "./catalog-matcher.ts"
import {
  cleanString,
  providerErrorMessage,
  redactedTheSportsDBURL,
  topLevelJSONKeys,
} from "./provider-team-lookup.ts"

export type ProviderLeagueArtwork = {
  idLeague: string
  strLeague: string
  strSport: string | null
  strBadge: string | null
  strLogo: string | null
}

export type LeagueArtworkEndpoint = "v2_lookup_league" | "v1_lookup_league" | "none"

export type LeagueArtworkDiagnostics = {
  leagueId: string
  leagueName: string
  endpoint: LeagueArtworkEndpoint
  httpStatus: number | null
  topLevelKeys: string[]
  providerMessage: string | null
  artworkFound: boolean
  usedLogoFallback: boolean
  rejectedUntrustedURLs: number
}

export type LeagueArtworkResult = {
  artwork: ProviderLeagueArtwork | null
  compactURL: string | null
  diagnostics: LeagueArtworkDiagnostics
  requestCount: number
}

const THESPORTSDB_V2_BASE = "https://www.thesportsdb.com/api/v2/json"
const THESPORTSDB_V1_BASE = "https://www.thesportsdb.com/api/v1/json"

/**
 * Verified TheSportsDB league IDs for FanGeo competition/league identities.
 * Super Bowl is intentionally absent: it is not a competition-level league in
 * TheSportsDB (name search returns Super Bowl of Poker).
 */
export const CATALOG_LEAGUE_PROVIDER_IDS: Record<string, string> = {
  "league-nba": "4387",
  "league-wnba": "4516",
  "league-nfl": "4391",
  "league-mlb": "4424",
  "league-nhl": "4380",
  "league-mls": "4346",
  "league-premier-league": "4328",
  "league-nwsl": "4521",
  "tournament-world-cup": "4429",
  "tournament-champions-league": "4480",
  "league-formula-one": "4370",
}

const REJECTED_ARTWORK_PATHS = [
  "/poster/",
  "/banner/",
  "/fanart/",
  "/trophy/",
  "/event/thumb",
  "/preview/",
]

export function isCompactCompetitionArtworkURL(raw: string | null | undefined): boolean {
  const trimmed = String(raw ?? "").trim()
  if (!trimmed || !isTheSportsDBArtworkURL(trimmed)) return false
  let path = ""
  try {
    path = new URL(trimmed).pathname.toLowerCase()
  } catch {
    return false
  }
  if (REJECTED_ARTWORK_PATHS.some((token) => path.includes(token))) return false
  if (path.includes("/event/") && !path.includes("/league/")) return false
  return path.includes("/league/badge") || path.includes("/league/logo") || path.includes("/badge")
}

export function compactCompetitionArtwork(
  badgeURL: string | null | undefined,
  logoURL: string | null | undefined,
): { url: string | null; usedLogoFallback: boolean; rejectedUntrustedURLs: number } {
  let rejectedUntrustedURLs = 0
  const candidates = [badgeURL, logoURL]
  for (const [index, candidate] of candidates.entries()) {
    const trimmed = String(candidate ?? "").trim()
    if (!trimmed) continue
    if (!isTheSportsDBArtworkURL(trimmed)) {
      rejectedUntrustedURLs += 1
      continue
    }
    if (!isCompactCompetitionArtworkURL(trimmed)) {
      rejectedUntrustedURLs += 1
      continue
    }
    return {
      url: trimmed,
      usedLogoFallback: index === 1,
      rejectedUntrustedURLs,
    }
  }
  return { url: null, usedLogoFallback: false, rejectedUntrustedURLs }
}

export function resolveCatalogLeagueProviderId(
  identity: SportsCatalogIdentity,
  teamLeagues: Array<{ id: string; league: string }>,
): string | null {
  const mapped = CATALOG_LEAGUE_PROVIDER_IDS[identity.catalogId]
  if (mapped) return mapped
  for (const league of teamLeagues) {
    const names = [identity.name, ...identity.aliases]
    if (names.some((name) => isExactLeagueNameMatch(league.league, name))) {
      return league.id
    }
  }
  return null
}

export function competitionArtworkTargets(
  teamLeagues: Array<{ id: string; league: string }>,
): Array<SportsCatalogIdentity & { providerLeagueId: string | null }> {
  return catalogLeagues()
    .filter((identity) => isStableCompetitionCatalogId(identity.catalogId))
    .map((identity) => ({
      ...identity,
      providerLeagueId: resolveCatalogLeagueProviderId(identity, teamLeagues),
    }))
}

export function extractProviderLeagueRows(data: unknown): unknown[] {
  if (!data || typeof data !== "object" || Array.isArray(data)) return []
  const record = data as Record<string, unknown>
  for (const key of ["leagues", "lookup", "league", "list"]) {
    const value = record[key]
    if (Array.isArray(value)) return value
    if (value && typeof value === "object") return [value]
  }
  return []
}

export function mapProviderLeagueArtwork(
  rows: unknown[],
  allowedArtworkURL: (raw: string | null) => string | null,
): ProviderLeagueArtwork | null {
  for (const row of rows) {
    if (!row || typeof row !== "object") continue
    const record = row as Record<string, unknown>
    const idLeague = cleanString(record.idLeague)
    const strLeague = cleanString(record.strLeague)
    if (!idLeague || !strLeague) continue
    return {
      idLeague,
      strLeague,
      strSport: cleanString(record.strSport),
      strBadge: allowedArtworkURL(cleanString(record.strBadge)),
      strLogo: allowedArtworkURL(cleanString(record.strLogo)),
    }
  }
  return null
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

export async function fetchLeagueArtwork(
  apiKey: string,
  leagueId: string,
  leagueName: string,
  allowedArtworkURL: (raw: string | null) => string | null,
  log: (message: string) => void = console.log,
): Promise<LeagueArtworkResult> {
  const empty: LeagueArtworkDiagnostics = {
    leagueId,
    leagueName,
    endpoint: "none",
    httpStatus: null,
    topLevelKeys: [],
    providerMessage: null,
    artworkFound: false,
    usedLogoFallback: false,
    rejectedUntrustedURLs: 0,
  }
  if (!apiKey || !leagueId) {
    return { artwork: null, compactURL: null, diagnostics: empty, requestCount: 0 }
  }

  let requestCount = 0
  const v2URL = `${THESPORTSDB_V2_BASE}/lookup/league/${encodeURIComponent(leagueId)}`
  log(`request ${redactedTheSportsDBURL(v2URL)}`)
  const v2 = await fetchJSON(v2URL, { "X-API-KEY": apiKey })
  requestCount += 1
  let rows = extractProviderLeagueRows(v2.data)
  let endpoint: LeagueArtworkEndpoint = "v2_lookup_league"
  let status = v2.status
  let keys = topLevelJSONKeys(v2.data)
  let message = providerErrorMessage(v2.data)

  if (rows.length === 0) {
    const v1URL = `${THESPORTSDB_V1_BASE}/${apiKey}/lookupleague.php?id=${encodeURIComponent(leagueId)}`
    log(`request ${redactedTheSportsDBURL(v1URL)}`)
    const v1 = await fetchJSON(v1URL)
    requestCount += 1
    rows = extractProviderLeagueRows(v1.data)
    endpoint = "v1_lookup_league"
    status = v1.status
    keys = topLevelJSONKeys(v1.data)
    message = providerErrorMessage(v1.data)
  }

  const artwork = mapProviderLeagueArtwork(rows, allowedArtworkURL)
  const compact = compactCompetitionArtwork(artwork?.strBadge, artwork?.strLogo)
  return {
    artwork,
    compactURL: compact.url,
    diagnostics: {
      leagueId,
      leagueName,
      endpoint: artwork ? endpoint : rows.length === 0 ? "none" : endpoint,
      httpStatus: status,
      topLevelKeys: keys,
      providerMessage: message,
      artworkFound: compact.url != null,
      usedLogoFallback: compact.usedLogoFallback,
      rejectedUntrustedURLs: compact.rejectedUntrustedURLs,
    },
    requestCount,
  }
}
