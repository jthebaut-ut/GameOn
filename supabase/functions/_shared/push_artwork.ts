/** Canonical optional rich-push artwork fields. Fail closed on untrusted hosts. */

export const PUSH_ARTWORK_URL_KEY = "artwork_url"
export const PUSH_ARTWORK_KIND_KEY = "artwork_kind"
export const PUSH_ARTWORK_ENTITY_KEY = "artwork_entity_id"

export type PushArtworkKind = "team" | "pro_team" | "user" | "group" | "player"

export function isTheSportsDBHost(host: string): boolean {
  const h = host.toLowerCase()
  return h === "www.thesportsdb.com"
    || h === "thesportsdb.com"
    || h === "r2.thesportsdb.com"
    || h.endsWith(".thesportsdb.com")
}

export function isSupabaseStorageHost(host: string, pathname: string): boolean {
  const h = host.toLowerCase()
  const path = pathname.toLowerCase()
  if (!path.includes("/storage/v1/object/")) return false
  return h.endsWith(".supabase.co")
    || h.endsWith(".supabase.in")
    || h === "supabase.co"
    || h === "supabase.in"
}

export function compactProviderArtworkURL(raw: string): string {
  const lower = raw.toLowerCase()
  if (lower.endsWith("/tiny") || lower.endsWith("/small") || lower.endsWith("/medium")) return raw
  try {
    const url = new URL(raw)
    if (!isTheSportsDBHost(url.host)) return raw
    return `${raw}/tiny`
  } catch {
    return raw
  }
}

export function trustedArtworkURL(raw: string | null | undefined): string | null {
  const value = String(raw ?? "").trim()
  if (!value || value.length > 1024) return null
  if (!/^https:\/\//i.test(value)) return null
  try {
    const url = new URL(value)
    if (url.protocol !== "https:") return null
    if (isTheSportsDBHost(url.host)) return compactProviderArtworkURL(url.toString())
    if (isSupabaseStorageHost(url.host, url.pathname)) return url.toString()
    return null
  } catch {
    return null
  }
}

export function pickTeamLogo(
  thumbnail: string | null | undefined,
  full: string | null | undefined,
): string | null {
  return trustedArtworkURL(thumbnail) ?? trustedArtworkURL(full)
}

export function pickUserAvatar(
  thumbnail: string | null | undefined,
  full: string | null | undefined,
): string | null {
  return trustedArtworkURL(thumbnail) ?? trustedArtworkURL(full)
}

function normTeam(raw: string | null | undefined): string {
  return String(raw ?? "").replace(/\s+/g, " ").trim().toLowerCase()
}

export function pickProGameScoreArtwork(input: {
  scoringTeam?: string | null
  homeTeam: string
  awayTeam: string
  homeBadgeURL?: string | null
  awayBadgeURL?: string | null
}): string | null {
  const scoring = normTeam(input.scoringTeam)
  if (!scoring) return null
  if (scoring === normTeam(input.homeTeam)) return trustedArtworkURL(input.homeBadgeURL)
  if (scoring === normTeam(input.awayTeam)) return trustedArtworkURL(input.awayBadgeURL)
  return null
}

export function pickProGameFinalArtwork(input: {
  homeTeam: string
  awayTeam: string
  homeScore: number
  awayScore: number
  homeBadgeURL?: string | null
  awayBadgeURL?: string | null
}): string | null {
  if (input.homeScore === input.awayScore) return null
  if (input.homeScore > input.awayScore) return trustedArtworkURL(input.homeBadgeURL)
  return trustedArtworkURL(input.awayBadgeURL)
}

export function pickChatGroupArtwork(input: {
  groupImageURL?: string | null
  teamLogoURL?: string | null
  senderAvatarURL?: string | null
}): string | null {
  return trustedArtworkURL(input.groupImageURL)
    ?? trustedArtworkURL(input.teamLogoURL)
    ?? trustedArtworkURL(input.senderAvatarURL)
}

export function applyPushArtwork(
  customData: Record<string, string>,
  url: string | null | undefined,
  kind: PushArtworkKind,
  entityId?: string | null,
): void {
  const trusted = trustedArtworkURL(url)
  if (!trusted) return
  customData[PUSH_ARTWORK_URL_KEY] = trusted
  customData[PUSH_ARTWORK_KIND_KEY] = kind
  const entity = String(entityId ?? "").trim()
  if (entity) customData[PUSH_ARTWORK_ENTITY_KEY] = entity
}
