import {
  CATALOG_IDENTITIES,
  type SportsCatalogIdentity,
} from "./catalog-identities.ts"

export type { SportsCatalogIdentity }

const GENERIC_TOKENS = new Set([
  "club",
  "city",
  "fc",
  "cf",
  "united",
  "team",
  "national",
  "hockey",
  "basketball",
  "football",
  "soccer",
])

export function normalizedIdentityText(raw: string): string {
  return String(raw ?? "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
}

function sportCompatible(catalogSport: string, providerSport: string): boolean {
  const left = normalizedIdentityText(catalogSport)
  const right = normalizedIdentityText(providerSport)
  if (!left || !right) return true
  if (left === right) return true
  const aliases: Record<string, string[]> = {
    soccer: ["football"],
    football: ["american football", "nfl"],
    basketball: ["nba", "wnba"],
    baseball: ["mlb"],
    hockey: ["nhl", "ice hockey"],
  }
  return (aliases[left] ?? []).includes(right) || (aliases[right] ?? []).includes(left)
}

function identitySearchNames(identity: SportsCatalogIdentity): string[] {
  const names = [identity.name, ...identity.aliases]
  return names.map(normalizedIdentityText).filter((name) => name.length >= 3)
}

function namesMatch(providerName: string, catalogName: string): boolean {
  if (!providerName || !catalogName) return false
  if (providerName === catalogName) return true
  if (GENERIC_TOKENS.has(catalogName)) return false
  if (catalogName.length <= 3) {
    return providerName.split(" ").includes(catalogName)
  }
  if (providerName.includes(catalogName) || catalogName.includes(providerName)) {
    return true
  }
  const providerTokens = providerName.split(" ")
  const catalogTokens = catalogName.split(" ")
  const lastProvider = providerTokens[providerTokens.length - 1] ?? ""
  const lastCatalog = catalogTokens[catalogTokens.length - 1] ?? ""
  if (
    lastProvider.length >= 4 &&
    lastCatalog.length >= 4 &&
    lastProvider === lastCatalog &&
    !GENERIC_TOKENS.has(lastProvider)
  ) {
    return true
  }
  return false
}

export function matchCatalogIdentities(input: {
  teamName: string
  league?: string | null
  sport?: string | null
  kind?: SportsCatalogIdentity["kind"]
}): SportsCatalogIdentity[] {
  const providerName = normalizedIdentityText(input.teamName)
  if (!providerName) return []
  const providerLeague = normalizedIdentityText(input.league ?? "")
  const providerSport = input.sport ?? ""
  const wantedKind = input.kind

  const matches: SportsCatalogIdentity[] = []
  for (const identity of CATALOG_IDENTITIES) {
    if (wantedKind && identity.kind !== wantedKind) continue
    if (identity.kind === "player" || identity.kind === "league") continue
    if (!sportCompatible(identity.sport, providerSport)) continue
    const catalogNames = identitySearchNames(identity)
    if (!catalogNames.some((name) => namesMatch(providerName, name))) continue
    matches.push(identity)
  }

  if (matches.length <= 1 || !providerLeague) return matches

  const leagueBoosted = matches.filter((identity) => {
    const league = normalizedIdentityText(identity.league)
    return league === providerLeague || providerLeague.includes(league) || league.includes(providerLeague)
  })
  return leagueBoosted.length > 0 ? leagueBoosted : matches
}

export function catalogPlayers(): SportsCatalogIdentity[] {
  return CATALOG_IDENTITIES.filter((identity) => identity.kind === "player")
}

const LEAGUE_DISPLAY_NAMES: Record<string, string> = {
  "english premier league": "Premier League",
  "spanish la liga": "La Liga",
  "italian serie a": "Serie A",
  "german bundesliga": "Bundesliga",
  "french ligue 1": "Ligue 1",
  "american major league soccer": "MLS",
  "mexican primera league": "Liga MX",
  "portuguese primeira liga": "Primeira Liga",
  "dutch eredivisie": "Eredivisie",
  "scottish premier league": "Scottish Premiership",
  "brazilian brasileirao": "Brasileirão",
  "argentinian primera division": "Argentine Primera División",
  "american nwsl": "NWSL",
  "american football": "NFL",
  "ice hockey": "NHL",
}

export function displayLeagueName(raw: string | null | undefined): string {
  const trimmed = String(raw ?? "").trim()
  if (!trimmed) return ""
  return LEAGUE_DISPLAY_NAMES[normalizedIdentityText(trimmed)] ?? trimmed
}

export function curatedPlayerCatalogId(input: {
  playerName: string
  sport?: string | null
}): string | null {
  const wanted = normalizedIdentityText(input.playerName)
  if (!wanted) return null
  const matches = catalogPlayers().filter((identity) => {
    if (!sportCompatible(identity.sport, input.sport ?? "")) return false
    return identitySearchNames(identity).includes(wanted)
  })
  return matches[0]?.catalogId ?? null
}

const STAFF_POSITIONS = new Set([
  "manager",
  "head coach",
  "coach",
  "assistant manager",
  "assistant coach",
  "goalkeeping coach",
  "goalkeeper coach",
  "fitness coach",
  "president",
  "owner",
  "chairman",
  "sporting director",
  "director",
  "scout",
  "physio",
  "physiotherapist",
  "kit man",
  "staff",
  "caretaker",
])

export function isRosterStaffPosition(raw: string | null | undefined): boolean {
  const normalized = normalizedIdentityText(raw ?? "")
  if (!normalized) return false
  if (STAFF_POSITIONS.has(normalized)) return true
  return normalized.includes("coach") || normalized.includes("manager") || normalized.includes("director")
}

export function isRetiredPlayerStatus(raw: string | null | undefined): boolean {
  const normalized = normalizedIdentityText(raw ?? "")
  return normalized === "retired" || normalized === "inactive"
}

export function catalogLeagues(): SportsCatalogIdentity[] {
  return CATALOG_IDENTITIES.filter((identity) => identity.kind === "league")
}

/** Exact name/alias only. Substring matching would bind Super Bowl of Poker to Super Bowl. */
export function isExactLeagueNameMatch(providerName: string, catalogName: string): boolean {
  const left = normalizedIdentityText(providerName)
  const right = normalizedIdentityText(catalogName)
  return left.length > 0 && left === right
}

export function matchCatalogLeagueIdentity(input: {
  leagueName: string
  sport?: string | null
}): SportsCatalogIdentity | null {
  const providerName = normalizedIdentityText(input.leagueName)
  if (!providerName) return null
  const matches = catalogLeagues().filter((identity) => {
    if (!sportCompatible(identity.sport, input.sport ?? "")) return false
    const names = [identity.name, ...identity.aliases]
    return names.some((name) => isExactLeagueNameMatch(providerName, name))
  })
  return matches.length === 1 ? matches[0] : null
}

export function isStableCompetitionCatalogId(catalogId: string): boolean {
  const id = String(catalogId ?? "").trim().toLowerCase()
  if (!id) return false
  if (id.startsWith("event-") || id.includes("event-tsdb-")) return false
  if (/super-bowl-[ivxlcdm0-9]+/.test(id)) return false
  return true
}

export function isTheSportsDBArtworkURL(raw: string | null | undefined): boolean {
  const trimmed = String(raw ?? "").trim()
  if (!trimmed) return false
  try {
    const host = new URL(trimmed).hostname.toLowerCase()
    return (
      host === "www.thesportsdb.com" ||
      host === "thesportsdb.com" ||
      host === "r2.thesportsdb.com" ||
      host.endsWith(".thesportsdb.com")
    )
  } catch {
    return false
  }
}

export function playerAllowsCreativeCommons(value: string | null | undefined): boolean {
  const normalized = String(value ?? "").trim().toLowerCase()
  return normalized === "yes" || normalized === "true" || normalized === "1"
}
