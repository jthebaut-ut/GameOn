type FifaTaggableMatch = {
  id: string
  external_id?: string
  sport: string
  league: string
  featured_event_slug: string | null
  payload: unknown
}

export const FIFA_WORLD_CUP_LEAGUE_ID = "4429"
export const FIFA_WORLD_CUP_LEAGUE_LABEL = "FIFA World Cup"
export const FIFA_WORLD_CUP_LEAGUE_ALTERNATE = "World Cup 2026"
export const FORCE_FIFA_WORLD_CUP_FEATURED_SLUG = "fifa_world_cup"

type FeaturedEventSlugSource = {
  slug: string
}

const NON_FIFA_WORLD_CUP_MARKERS = [
  "fiba",
  "basketball world cup",
  "cricket world cup",
  "icc world cup",
  "t20 world cup",
  "rugby world cup",
  "hockey world cup",
  "american football",
  "nfl",
  "gridiron",
  "us football",
  "uefa u19",
  "uefa u20",
  "uefa u21",
  "u19 world cup",
  "u20 world cup",
  "u21 world cup",
  "club friendly",
  "club friendlies",
  "international friendly",
  "international friendlies",
  "fifa club world cup",
  "women s world cup",
  "women world cup",
  "fifa women",
]

export function isFifaWorldCupFeaturedSlug(slug: string): boolean {
  const normalized = normalizeTaggingText(slug).replace(/ /g, "-")
  return normalized.includes("fifa-world-cup")
    || normalized === "fifa-wc"
    || normalized.includes("world-cup-2026")
    || (normalized.includes("fifa") && normalized.includes("world-cup"))
}

export function resolveFifaWorldCupFeaturedSlug(events: FeaturedEventSlugSource[]): string {
  const hasFifa = events.some((event) => isFifaWorldCupFeaturedSlug(event.slug))
  if (hasFifa) {
    return FORCE_FIFA_WORLD_CUP_FEATURED_SLUG
  }

  return FORCE_FIFA_WORLD_CUP_FEATURED_SLUG
}

export function resolveFeaturedEventStorageSlug(slug: string): string {
  const trimmed = slug.trim()
  if (!trimmed) {
    return trimmed
  }

  if (isFifaWorldCupFeaturedSlug(trimmed)) {
    return FORCE_FIFA_WORLD_CUP_FEATURED_SLUG
  }

  return trimmed
}

export function defaultFifaWorldCupProviderConfigs(
  featuredEvent: FeaturedEventSlugSource & { sport: string | null },
): Array<{ leagueId: string; season: string; sport: string | null; league: string | null }> | null {
  if (!isFifaWorldCupFeaturedSlug(featuredEvent.slug)) return null
  return [{
    leagueId: FIFA_WORLD_CUP_LEAGUE_ID,
    season: "2026",
    sport: featuredEvent.sport ?? "Soccer",
    league: FIFA_WORLD_CUP_LEAGUE_LABEL,
  }]
}

export async function fetchTodayFifaWorldCupExternalIds(apiKey: string): Promise<Set<string>> {
  const ids = new Set<string>()
  const today = new Date().toISOString().slice(0, 10)
  const url = `https://www.thesportsdb.com/api/v1/json/${apiKey}/eventsday.php?d=${encodeURIComponent(today)}&s=Soccer`

  try {
    const response = await fetch(url)
    if (!response.ok) {
      fifaLog(`skippedReason=eventsday_fetch http=${response.status}`)
      return ids
    }

    const data = await response.json()
    const events = Array.isArray(data?.events) ? data.events : []
    fifaLog(`fetched=eventsday count=${events.length}`)

    for (const event of events) {
      if (String(event?.idLeague ?? "").trim() !== FIFA_WORLD_CUP_LEAGUE_ID) continue
      const externalId = String(event?.idEvent ?? "").trim()
      if (externalId) ids.add(externalId)
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    fifaLog(`skippedReason=eventsday_fetch error=${message}`)
  }

  return ids
}

export function applyFifaWorldCupTagging(
  matches: FifaTaggableMatch[],
  featuredSlug: string,
  todayFifaEventIds: Set<string> = new Set(),
): void {
  let fetched = 0
  for (const match of matches) {
    if (!isSoccerMatch(match)) continue
    fetched += 1

    const candidateReason = fifaWorldCupCandidateReason(match, todayFifaEventIds)
    if (!candidateReason) {
      const searchable = buildSearchable(match)
      if (searchable.includes("world") || searchable.includes("fifa")) {
        fifaLog(`skippedReason=${match.id} reason=not_candidate league=${match.league}`)
      }
      continue
    }

    fifaLog(`candidate=${match.id} reason=${candidateReason} league=${match.league}`)
  }

  fifaLog(`fetched=${fetched}`)

  for (const match of matches) {
    const candidateReason = fifaWorldCupCandidateReason(match, todayFifaEventIds)
    if (!candidateReason) continue

    const alreadyTagged = cleanString(match.featured_event_slug)
    match.featured_event_slug = alreadyTagged ?? featuredSlug
    match.league = normalizeFifaWorldCupLeagueLabel(match)
    match.payload = enrichFifaWorldCupPayload(match.payload, featuredSlug, candidateReason)

    fifaLog(`inserted=${match.id} taggedSlug=${match.featured_event_slug} league=${match.league} reason=${candidateReason}`)
    fifaLog(`taggedSlug=${match.featured_event_slug} id=${match.id}`)
  }
}

export function mergeFeaturedMetadataOntoLiveMatch(
  live: FifaTaggableMatch,
  scheduled: FifaTaggableMatch,
): void {
  if (scheduled.featured_event_slug && !cleanString(live.featured_event_slug)) {
    live.featured_event_slug = scheduled.featured_event_slug
  }

  if (isFifaWorldCupFeaturedSlug(scheduled.featured_event_slug ?? "")) {
    live.league = normalizeFifaWorldCupLeagueLabel({
      ...live,
      league: scheduled.league || live.league,
      payload: scheduled.payload ?? live.payload,
    })
    live.payload = enrichFifaWorldCupPayload(
      live.payload,
      scheduled.featured_event_slug ?? resolveFifaWorldCupFeaturedSlug([]),
      "featured_merge",
    )
  } else if (scheduled.league && isGenericLeagueLabel(live.league) && !isGenericLeagueLabel(scheduled.league)) {
    live.league = scheduled.league
  }

  if (scheduled.payload && typeof scheduled.payload === "object" && live.payload && typeof live.payload === "object") {
    live.payload = {
      ...(live.payload as Record<string, unknown>),
      ...(scheduled.payload as Record<string, unknown>),
      fangeo_featured_event_slug: cleanString(live.featured_event_slug)
        ?? payloadString(scheduled.payload, "fangeo_featured_event_slug"),
    }
  }
}

export function resolveSportsDBLeagueLabel(
  event: Record<string, unknown>,
  fallbackLeague?: string,
): string {
  const league = cleanString(event?.strLeague) ?? cleanString(event?.strLeagueAlternate)
  if (league) return league

  const idLeague = cleanString(event?.idLeague)
  if (idLeague === FIFA_WORLD_CUP_LEAGUE_ID) return FIFA_WORLD_CUP_LEAGUE_LABEL

  return fallbackLeague ?? "Sports"
}

function fifaWorldCupCandidateReason(
  match: FifaTaggableMatch,
  todayFifaEventIds: Set<string>,
): string | null {
  if (!isSoccerMatch(match)) return null

  const externalId = cleanString(match.external_id) ?? payloadString(match.payload, "idEvent")
  if (externalId && todayFifaEventIds.has(externalId)) return "eventsday_idLeague"

  const searchable = buildSearchable(match)
  if (!searchable || isExcludedNonFifaWorldCup(searchable)) return null

  const idLeague = payloadString(match.payload, "idLeague")
  if (idLeague === FIFA_WORLD_CUP_LEAGUE_ID) return "idLeague"

  if (searchable.includes("fifa world cup") || searchable.includes("world cup 2026")) {
    return "league_text"
  }

  if (searchable.includes("world cup") && searchable.includes("fifa")) {
    return "league_text"
  }

  return null
}

function normalizeFifaWorldCupLeagueLabel(match: FifaTaggableMatch): string {
  const searchable = buildSearchable(match)
  if (searchable.includes("world cup 2026")) return "World Cup 2026"
  if (searchable.includes("fifa world cup")) return FIFA_WORLD_CUP_LEAGUE_LABEL
  return FIFA_WORLD_CUP_LEAGUE_LABEL
}

function enrichFifaWorldCupPayload(
  payload: unknown,
  featuredSlug: string,
  reason: string,
): Record<string, unknown> {
  const base = payload && typeof payload === "object"
    ? { ...(payload as Record<string, unknown>) }
    : {}

  return {
    ...base,
    idLeague: cleanString(base.idLeague) ?? FIFA_WORLD_CUP_LEAGUE_ID,
    strLeague: cleanString(base.strLeague) ?? FIFA_WORLD_CUP_LEAGUE_LABEL,
    strLeagueAlternate: cleanString(base.strLeagueAlternate) ?? FIFA_WORLD_CUP_LEAGUE_ALTERNATE,
    fangeo_featured_event_slug: featuredSlug,
    fangeo_fifa_world_cup_tag_reason: reason,
  }
}

function buildSearchable(match: FifaTaggableMatch): string {
  return normalizeTaggingText([
    match.sport,
    match.league,
    payloadString(match.payload, "strSport"),
    payloadString(match.payload, "strLeague"),
    payloadString(match.payload, "strLeagueAlternate"),
    payloadString(match.payload, "strEvent"),
    payloadString(match.payload, "strEventAlternate"),
    payloadString(match.payload, "strDescription"),
  ].join(" "))
}

function isSoccerMatch(match: FifaTaggableMatch): boolean {
  const sport = normalizeTaggingText([
    match.sport,
    payloadString(match.payload, "strSport"),
  ].join(" "))

  if (!sport) return false
  if (["american football", "nfl", "gridiron", "us football"].some((marker) => sport.includes(marker))) {
    return false
  }
  return sport.includes("soccer") || sport.includes("football") || sport.includes("association football")
}

function isExcludedNonFifaWorldCup(searchable: string): boolean {
  return NON_FIFA_WORLD_CUP_MARKERS.some((marker) => searchable.includes(marker))
}

function isGenericLeagueLabel(league: string): boolean {
  const normalized = normalizeTaggingText(league)
  return !normalized || normalized === "sports" || normalized === "soccer" || normalized === "football"
}

function normalizeTaggingText(raw: string): string {
  return raw
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/&/g, " and ")
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
}

function payloadString(payload: unknown, key: string): string {
  if (!payload || typeof payload !== "object") return ""
  const value = (payload as Record<string, unknown>)[key]
  return cleanString(value) ?? ""
}

function cleanString(value: unknown): string | null {
  const trimmed = String(value ?? "").trim()
  return trimmed ? trimmed : null
}

function fifaLog(message: string): void {
  console.log(`[LiveSyncFIFAWC] ${message}`)
}
