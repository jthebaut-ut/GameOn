// Privileged professional-team artwork + roster-player enrichment (TheSportsDB → public.sports_provider_identities).
// Also ingests compact league/competition badges via lookupleague for catalog identities
// stored as kind=league (World Cup, Champions League, NBA, …). Super Bowl is considered
// but not bound to a year-specific event or Super Bowl of Poker.
// Auth: service-role bearer OR x-cron-secret
//   (SPORTS_PROVIDER_ARTWORK_CRON_SECRET / SPORTS_SYNC_CRON_SECRET / SYNC_LIVE_MATCHES_CRON_SECRET).
// Team lookup: V2 GET /api/v2/json/list/teams/{idLeague} with X-API-KEY,
//   fallback V1 search_all_teams.php?id= / ?l=. Never lookup_all_teams.php.
// Roster lookup: V2 GET /api/v2/json/list/players/{idTeam} with X-API-KEY,
//   fallback V1 lookup_all_players.php?id=. Bounded by SPORTS_PROVIDER_ROSTER_LOOKUPS_PER_RUN (default 40).
// League artwork: V2 GET /api/v2/json/lookup/league/{idLeague}, fallback V1 lookupleague.php?id=.
//   Bounded by SPORTS_PROVIDER_LEAGUE_LOOKUPS_PER_RUN (default 40). Exact name/alias match only.
// Manual test:
//   curl -X POST "$SUPABASE_URL/functions/v1/sync-sports-provider-artwork" \
//     -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
//     -H "Content-Type: application/json" -d '{"force":true}'
// Deploy (do not run from this task):
//   supabase functions deploy sync-sports-provider-artwork --project-ref <PROJECT_REF>
// Do NOT invoke from iOS/user JWTs. The paid key stays in THESPORTSDB_API_KEY.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2"
import {
  authorizeSportsWorkerRequest,
  readServiceRoleKey,
  sportsWorkerAuthLog,
} from "../_shared/sports_worker_auth.ts"
import { CATALOG_IDENTITIES } from "./catalog-identities.ts"
import {
  catalogPlayers,
  curatedPlayerCatalogId,
  displayLeagueName,
  isTheSportsDBArtworkURL,
  matchCatalogIdentities,
  playerAllowsCreativeCommons,
} from "./catalog-matcher.ts"
import {
  competitionArtworkTargets,
  fetchLeagueArtwork,
} from "./provider-league-artwork.ts"
import {
  fetchTeamRoster,
  rosterPlayerAllowsArtwork,
} from "./provider-roster-lookup.ts"
import {
  cleanString,
  fetchLeagueTeams,
  redactedTheSportsDBURL,
  type LeagueConfig,
  type LeagueTeamLookupDiagnostics,
  type ProviderTeam,
} from "./provider-team-lookup.ts"

type EdgeSupabaseClient = SupabaseClient<any, "public", any>

const FUNCTION_NAME = "sync-sports-provider-artwork"
const PROVIDER = "thesportsdb"
const DEFAULT_TTL_DAYS = 30
const REQUEST_GAP_MS = 280
const MAX_PLAYER_LOOKUPS_PER_RUN = 20
const DEFAULT_MAX_ROSTER_LOOKUPS_PER_RUN = 40
const MIN_FRESH_ROSTER_PLAYERS = 8

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-cron-secret, x-fangeo-cron-secret",
}

type UpsertRow = {
  catalog_id: string
  kind: string
  provider: string
  provider_team_id: string | null
  provider_player_id: string | null
  provider_league_id: string | null
  canonical_name: string
  league: string | null
  sport: string | null
  country: string | null
  badge_url: string | null
  logo_url: string | null
  player_cutout_url: string | null
  player_creative_commons: boolean | null
  refreshed_at: string
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  })
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

function envList(name: string, fallback: string[]): string[] {
  const raw = Deno.env.get(name)?.trim() ?? ""
  if (!raw) return fallback
  return raw.split(",").map((part) => part.trim()).filter(Boolean)
}

function configuredLeagues(): LeagueConfig[] {
  const raw = Deno.env.get("SPORTS_PROVIDER_ARTWORK_LEAGUES")?.trim()
  if (raw) {
    try {
      const parsed = JSON.parse(raw) as LeagueConfig[]
      if (Array.isArray(parsed) && parsed.length > 0) return parsed
    } catch {
      // fall through to defaults
    }
  }
  return [
    { id: "4387", sport: "Basketball", league: "NBA", kind: "team" },
    // 4516 is WNBA. 4388 is NBA G League — do not use it here.
    { id: "4516", sport: "Basketball", league: "WNBA", kind: "team" },
    { id: "4391", sport: "American Football", league: "NFL", kind: "team" },
    { id: "4424", sport: "Baseball", league: "MLB", kind: "team" },
    { id: "4380", sport: "Ice Hockey", league: "NHL", kind: "team" },
    { id: "4328", sport: "Soccer", league: "English Premier League", kind: "team" },
    { id: "4335", sport: "Soccer", league: "Spanish La Liga", kind: "team" },
    { id: "4331", sport: "Soccer", league: "German Bundesliga", kind: "team" },
    { id: "4332", sport: "Soccer", league: "Italian Serie A", kind: "team" },
    { id: "4334", sport: "Soccer", league: "French Ligue 1", kind: "team" },
    { id: "4346", sport: "Soccer", league: "American Major League Soccer", kind: "team" },
    { id: "4350", sport: "Soccer", league: "Mexican Primera League", kind: "team" },
    { id: "4344", sport: "Soccer", league: "Portuguese Primeira Liga", kind: "team" },
    { id: "4337", sport: "Soccer", league: "Dutch Eredivisie", kind: "team" },
    { id: "4330", sport: "Soccer", league: "Scottish Premier League", kind: "team" },
    { id: "4351", sport: "Soccer", league: "Brazilian Brasileirao", kind: "team" },
    { id: "4406", sport: "Soccer", league: "Argentinian Primera Division", kind: "team" },
    { id: "4633", sport: "Soccer", league: "J1 League", kind: "team" },
    { id: "4668", sport: "Soccer", league: "Saudi-Arabian Pro League", kind: "team" },
    { id: "4689", sport: "Soccer", league: "South Korean K League 1", kind: "team" },
    { id: "4521", sport: "Soccer", league: "American NWSL", kind: "team" },
    { id: "4429", sport: "Soccer", league: "FIFA World Cup", kind: "national_team" },
  ]
}

function ttlDays(): number {
  const parsed = Number(Deno.env.get("SPORTS_PROVIDER_ARTWORK_TTL_DAYS") ?? "")
  return Number.isFinite(parsed) && parsed > 0 ? parsed : DEFAULT_TTL_DAYS
}

function allowedArtworkURL(raw: string | null): string | null {
  if (!raw || !isTheSportsDBArtworkURL(raw)) return null
  return raw.trim()
}

async function fetchSearchPlayer(
  apiKey: string,
  playerName: string,
): Promise<{
  idPlayer: string
  strPlayer: string
  strCutout: string | null
  strThumb: string | null
  strCreativeCommons: string | null
  strSport: string | null
  strTeam: string | null
} | null> {
  const url =
    `https://www.thesportsdb.com/api/v1/json/${apiKey}/searchplayers.php?p=${encodeURIComponent(playerName)}`
  console.log(`[${FUNCTION_NAME}] request ${redactedTheSportsDBURL(url)}`)
  const response = await fetch(url)
  if (!response.ok) return null
  const data = await response.json()
  const rows = Array.isArray(data?.player) ? data.player : []
  const wanted = playerName.trim().toLowerCase()
  const exact = rows.find((row: Record<string, unknown>) =>
    String(row?.strPlayer ?? "").trim().toLowerCase() === wanted
  ) ?? rows[0]
  if (!exact) return null
  return {
    idPlayer: cleanString(exact.idPlayer) ?? "",
    strPlayer: cleanString(exact.strPlayer) ?? playerName,
    strCutout: allowedArtworkURL(cleanString(exact.strCutout)),
    strThumb: allowedArtworkURL(cleanString(exact.strThumb)),
    strCreativeCommons: cleanString(exact.strCreativeCommons),
    strSport: cleanString(exact.strSport),
    strTeam: cleanString(exact.strTeam),
  }
}

function maxRosterLookupsPerRun(): number {
  const parsed = Number(Deno.env.get("SPORTS_PROVIDER_ROSTER_LOOKUPS_PER_RUN") ?? "")
  return Number.isFinite(parsed) && parsed > 0 ? parsed : DEFAULT_MAX_ROSTER_LOOKUPS_PER_RUN
}

function leagueRosterPriority(leagueId: string): number {
  const order = [
    "4387",
    "4516",
    "4424",
    "4391",
    "4380",
    "4328",
    "4335",
    "4332",
    "4331",
    "4334",
    "4346",
    "4350",
  ]
  const index = order.indexOf(leagueId)
  return index === -1 ? 100 : index
}

type RosterTeamTarget = {
  idTeam: string
  strTeam: string
  league: LeagueConfig
}

function identityRowForProviderTeam(
  team: ProviderTeam,
  league: LeagueConfig,
): UpsertRow {
  const identities = matchCatalogIdentities({
    teamName: team.strTeam,
    league: team.strLeague,
    sport: team.strSport,
    kind: league.kind,
  })
  const identity = identities[0]
  const now = new Date().toISOString()
  return {
    catalog_id: identity?.catalogId ?? `provider-team-${team.idTeam}`,
    kind: identity?.kind ?? league.kind,
    provider: PROVIDER,
    provider_team_id: team.idTeam,
    provider_player_id: null,
    provider_league_id: league.id,
    canonical_name: identity?.name ?? team.strTeam,
    league: identity?.league ?? displayLeagueName(league.league),
    sport: identity?.sport ?? league.sport,
    country: team.strCountry,
    badge_url: team.strBadge,
    logo_url: team.strLogo,
    player_cutout_url: null,
    player_creative_commons: null,
    refreshed_at: now,
  }
}

function rowsFromProviderTeam(
  team: ProviderTeam,
  league: LeagueConfig,
): UpsertRow[] {
  return [identityRowForProviderTeam(team, league)]
}

serve(async (req) => {
  const requestId = req.headers.get("x-request-id") ?? req.headers.get("sb-request-id")

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders })
  }

  const auth = authorizeSportsWorkerRequest(req, {
    cronSecretEnvNames: [
      "SPORTS_PROVIDER_ARTWORK_CRON_SECRET",
      "SPORTS_SYNC_CRON_SECRET",
      "SYNC_LIVE_MATCHES_CRON_SECRET",
    ],
  })
  if (!auth.accepted) {
    sportsWorkerAuthLog(FUNCTION_NAME, "unauthorized", {
      reason: auth.reason,
      requestId,
    })
    return json({ success: false, error: "unauthorized" }, auth.reason === "method_not_allowed" ? 405 : 401)
  }
  sportsWorkerAuthLog(FUNCTION_NAME, "authorized", {
    source: auth.source,
    requestId,
  })

  const supabaseUrl = Deno.env.get("PROJECT_URL") ?? Deno.env.get("SUPABASE_URL")
  const serviceRoleKey = readServiceRoleKey()
  const apiKey = Deno.env.get("THESPORTSDB_API_KEY")?.trim() ?? ""
  if (!supabaseUrl || !serviceRoleKey) {
    return json({ success: false, error: "Missing Supabase service env vars" }, 500)
  }
  if (!apiKey) {
    return json({ success: false, error: "THESPORTSDB_API_KEY missing" }, 500)
  }

  let force = false
  try {
    const body = await req.json()
    force = body?.force === true
  } catch {
    force = false
  }

  const supabase: EdgeSupabaseClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  })

  const ttlMs = ttlDays() * 24 * 60 * 60 * 1000
  const staleBefore = new Date(Date.now() - ttlMs).toISOString()
  const leagues = configuredLeagues()
  const counts = {
    catalogIdentities: CATALOG_IDENTITIES.length,
    leaguesConsidered: leagues.length,
    leaguesFetched: 0,
    leaguesSkippedFresh: 0,
    providerTeams: 0,
    teamsConsideredForRoster: 0,
    teamsWithRosterData: 0,
    teamsSkippedFreshRoster: 0,
    rosterLookups: 0,
    playersFetched: 0,
    uniquePlayers: 0,
    playersSkippedFresh: 0,
    playersSkippedStaff: 0,
    playersMissingArtwork: 0,
    matchedCatalogRows: 0,
    upserted: 0,
    playerLookups: 0,
    playersUpserted: 0,
    providerRequests: 0,
    teamUpserts: 0,
    rosterFailures: 0,
    competitionsConsidered: 0,
    competitionsMatched: 0,
    competitionProviderRequests: 0,
    competitionArtworkFound: 0,
    competitionArtworkMissing: 0,
    leagueLevelFallbackUsed: 0,
    eventLevelArtworkFound: 0,
    rejectedUntrustedURLs: 0,
  }

  const upserts: UpsertRow[] = []
  const rosterTargets: RosterTeamTarget[] = []
  const seenTeamIds = new Set<string>()
  let nbaDiagnostics: LeagueTeamLookupDiagnostics | null = null

  for (const league of leagues) {
    let teams: ProviderTeam[] = []
    if (!force) {
      const { count } = await supabase
        .from("sports_provider_identities")
        .select("catalog_id", { count: "exact", head: true })
        .eq("provider_league_id", league.id)
        .eq("provider", PROVIDER)
        .not("badge_url", "is", null)
        .gte("refreshed_at", staleBefore)
      if ((count ?? 0) >= 8) {
        counts.leaguesSkippedFresh += 1
        const { data: stored } = await supabase
          .from("sports_provider_identities")
          .select("provider_team_id, canonical_name")
          .eq("provider_league_id", league.id)
          .eq("provider", PROVIDER)
          .in("kind", ["team", "national_team"])
        for (const row of stored ?? []) {
          const idTeam = cleanString(row.provider_team_id)
          const strTeam = cleanString(row.canonical_name)
          if (!idTeam || !strTeam || seenTeamIds.has(idTeam)) continue
          seenTeamIds.add(idTeam)
          rosterTargets.push({ idTeam, strTeam, league })
        }
        continue
      }
    }

    const result = await fetchLeagueTeams(
      apiKey,
      league,
      allowedArtworkURL,
      (message) => console.log(`[${FUNCTION_NAME}] ${message}`),
    )
    counts.providerRequests += result.requestCount
    counts.leaguesFetched += 1
    counts.providerTeams += result.teams.length
    teams = result.teams
    if (league.id === "4387") {
      nbaDiagnostics = result.diagnostics
      console.log(
        `[${FUNCTION_NAME}] nba_diagnostics leagueId=${result.diagnostics.leagueId} endpoint=${result.diagnostics.endpoint} status=${result.diagnostics.httpStatus} contentType=${result.diagnostics.contentType ?? "-"} keys=${result.diagnostics.topLevelKeys.join(",") || "-"} teamCount=${result.diagnostics.teamCount} message=${result.diagnostics.providerMessage ?? "-"}`,
      )
    }
    if (result.teams.length === 0) {
      console.warn(
        `[${FUNCTION_NAME}] league_teams_empty league=${league.id} endpoint=${result.diagnostics.endpoint} status=${result.diagnostics.httpStatus} keys=${result.diagnostics.topLevelKeys.join(",") || "-"} message=${result.diagnostics.providerMessage ?? "-"}`,
      )
    }
    for (const team of teams) {
      const rows = rowsFromProviderTeam(team, league)
      counts.matchedCatalogRows += rows.length
      upserts.push(...rows)
      if (!seenTeamIds.has(team.idTeam)) {
        seenTeamIds.add(team.idTeam)
        rosterTargets.push({ idTeam: team.idTeam, strTeam: team.strTeam, league })
      }
    }
    await sleep(REQUEST_GAP_MS)
  }

  const competitionTargets = competitionArtworkTargets(
    leagues.map((league) => ({ id: league.id, league: league.league })),
  )
  counts.competitionsConsidered = competitionTargets.length
  const maxCompetitionLookups = Number(Deno.env.get("SPORTS_PROVIDER_LEAGUE_LOOKUPS_PER_RUN") ?? "")
  const competitionLookupCap =
    Number.isFinite(maxCompetitionLookups) && maxCompetitionLookups > 0 ? maxCompetitionLookups : 40
  let competitionLookups = 0
  for (const identity of competitionTargets) {
    if (!identity.providerLeagueId) {
      counts.competitionArtworkMissing += 1
      continue
    }
    counts.competitionsMatched += 1
    if (!force) {
      const { data } = await supabase
        .from("sports_provider_identities")
        .select("refreshed_at, badge_url, logo_url")
        .eq("catalog_id", identity.catalogId)
        .eq("kind", "league")
        .maybeSingle()
      const refreshedAt = data?.refreshed_at ? Date.parse(String(data.refreshed_at)) : 0
      const hasArtwork = Boolean(data?.badge_url || data?.logo_url)
      if (hasArtwork && Number.isFinite(refreshedAt) && Date.now() - refreshedAt < ttlMs) {
        continue
      }
    }
    if (competitionLookups >= competitionLookupCap) {
      counts.competitionArtworkMissing += 1
      continue
    }
    const result = await fetchLeagueArtwork(
      apiKey,
      identity.providerLeagueId,
      identity.name,
      allowedArtworkURL,
      (message) => console.log(`[${FUNCTION_NAME}] ${message}`),
    )
    competitionLookups += 1
    counts.competitionProviderRequests += result.requestCount
    counts.providerRequests += result.requestCount
    counts.rejectedUntrustedURLs += result.diagnostics.rejectedUntrustedURLs
    if (result.diagnostics.usedLogoFallback) counts.leagueLevelFallbackUsed += 1
    await sleep(REQUEST_GAP_MS)
    if (!result.compactURL) {
      counts.competitionArtworkMissing += 1
      continue
    }
    counts.competitionArtworkFound += 1
    upserts.push({
      catalog_id: identity.catalogId,
      kind: "league",
      provider: PROVIDER,
      provider_team_id: null,
      provider_player_id: null,
      provider_league_id: identity.providerLeagueId,
      canonical_name: identity.name,
      league: identity.league,
      sport: identity.sport,
      country: null,
      badge_url: result.compactURL,
      logo_url: result.artwork?.strLogo ?? null,
      player_cutout_url: null,
      player_creative_commons: null,
      refreshed_at: new Date().toISOString(),
    })
  }

  rosterTargets.sort((lhs, rhs) => {
    const delta = leagueRosterPriority(lhs.league.id) - leagueRosterPriority(rhs.league.id)
    if (delta !== 0) return delta
    return lhs.strTeam.localeCompare(rhs.strTeam)
  })
  counts.teamsConsideredForRoster = rosterTargets.length

  const maxRosters = maxRosterLookupsPerRun()
  const seenPlayerIds = new Set<string>()
  for (const target of rosterTargets) {
    if (counts.rosterLookups >= maxRosters) break
    if (!force) {
      const { count } = await supabase
        .from("sports_provider_identities")
        .select("catalog_id", { count: "exact", head: true })
        .eq("kind", "player")
        .eq("provider", PROVIDER)
        .eq("provider_team_id", target.idTeam)
        .gte("refreshed_at", staleBefore)
      if ((count ?? 0) >= MIN_FRESH_ROSTER_PLAYERS) {
        counts.teamsSkippedFreshRoster += 1
        counts.playersSkippedFresh += count ?? 0
        continue
      }
    }

    const roster = await fetchTeamRoster(
      apiKey,
      target.idTeam,
      target.strTeam,
      allowedArtworkURL,
      (message) => console.log(`[${FUNCTION_NAME}] ${message}`),
    )
    counts.providerRequests += roster.requestCount
    counts.rosterLookups += 1
    counts.playersSkippedStaff += roster.diagnostics.skippedStaff
    await sleep(REQUEST_GAP_MS)

    if (roster.players.length === 0) {
      counts.rosterFailures += 1
      console.warn(
        `[${FUNCTION_NAME}] roster_empty team=${target.idTeam} name=${target.strTeam} endpoint=${roster.diagnostics.endpoint} status=${roster.diagnostics.httpStatus}`,
      )
      continue
    }

    counts.teamsWithRosterData += 1
    counts.playersFetched += roster.players.length
    const now = new Date().toISOString()
    const leagueName = displayLeagueName(target.league.league)
    for (const player of roster.players) {
      if (seenPlayerIds.has(player.idPlayer)) continue
      seenPlayerIds.add(player.idPlayer)
      const curatedId = curatedPlayerCatalogId({
        playerName: player.strPlayer,
        sport: player.strSport ?? target.league.sport,
      })
      const allowsCC = rosterPlayerAllowsArtwork(player)
      const cutout = allowsCC ? (player.strCutout ?? player.strThumb) : null
      if (!cutout) counts.playersMissingArtwork += 1
      upserts.push({
        catalog_id: curatedId ?? `player-tsdb-${player.idPlayer}`,
        kind: "player",
        provider: PROVIDER,
        provider_team_id: player.idTeam ?? target.idTeam,
        provider_player_id: player.idPlayer,
        provider_league_id: target.league.id,
        canonical_name: player.strPlayer,
        league: leagueName,
        sport: target.league.sport,
        country: player.strNationality,
        badge_url: null,
        logo_url: null,
        player_cutout_url: cutout,
        player_creative_commons: allowsCC,
        refreshed_at: now,
      })
      counts.playersUpserted += 1
    }
  }
  counts.uniquePlayers = seenPlayerIds.size

  const playerIdentities = catalogPlayers().filter((identity) =>
    ["Soccer", "Basketball", "Football", "Baseball", "Hockey"].includes(identity.sport)
  )
  for (const identity of playerIdentities) {
    if (counts.playerLookups >= MAX_PLAYER_LOOKUPS_PER_RUN) break
    if (!force) {
      const { data } = await supabase
        .from("sports_provider_identities")
        .select("refreshed_at, player_cutout_url, player_creative_commons")
        .eq("catalog_id", identity.catalogId)
        .maybeSingle()
      const refreshedAt = data?.refreshed_at ? Date.parse(String(data.refreshed_at)) : 0
      if (
        Number.isFinite(refreshedAt) &&
        Date.now() - refreshedAt < ttlMs
      ) {
        continue
      }
    }
    const found = await fetchSearchPlayer(apiKey, identity.name)
    counts.providerRequests += 1
    counts.playerLookups += 1
    await sleep(REQUEST_GAP_MS)
    if (!found?.idPlayer) continue
    const allowsCC = playerAllowsCreativeCommons(found.strCreativeCommons)
    const cutout = allowsCC ? (found.strCutout ?? found.strThumb) : null
    upserts.push({
      catalog_id: identity.catalogId,
      kind: "player",
      provider: PROVIDER,
      provider_team_id: null,
      provider_player_id: found.idPlayer,
      provider_league_id: null,
      canonical_name: identity.name,
      league: identity.league,
      sport: identity.sport,
      country: null,
      badge_url: null,
      logo_url: null,
      player_cutout_url: cutout,
      player_creative_commons: allowsCC,
      refreshed_at: new Date().toISOString(),
    })
    counts.playersUpserted += 1
  }

  const unique = new Map<string, UpsertRow>()
  for (const row of upserts) {
    const existing = unique.get(row.catalog_id)
    if (
      existing?.kind === "player" &&
      existing.provider_team_id &&
      row.kind === "player" &&
      !row.provider_team_id
    ) {
      continue
    }
    unique.set(row.catalog_id, row)
  }
  const payload = [...unique.values()]
  if (payload.length > 0) {
    const { error } = await supabase
      .from("sports_provider_identities")
      .upsert(payload, { onConflict: "catalog_id" })
    if (error) {
      console.warn(`[${FUNCTION_NAME}] upsert failed ${error.message}`)
      return json({ success: false, error: "upsert_failed" }, 500)
    }
    counts.upserted = payload.length
    counts.teamUpserts = payload.filter((row) => row.kind !== "player").length
  }

  console.log(
    `[${FUNCTION_NAME}] complete leaguesFetched=${counts.leaguesFetched} skippedFresh=${counts.leaguesSkippedFresh} providerTeams=${counts.providerTeams} rosterLookups=${counts.rosterLookups} teamsWithRoster=${counts.teamsWithRosterData} uniquePlayers=${counts.uniquePlayers} playersUpserted=${counts.playersUpserted} missingArtwork=${counts.playersMissingArtwork} competitionsConsidered=${counts.competitionsConsidered} competitionsMatched=${counts.competitionsMatched} competitionArtworkFound=${counts.competitionArtworkFound} competitionArtworkMissing=${counts.competitionArtworkMissing} leagueLevelFallbackUsed=${counts.leagueLevelFallbackUsed} eventLevelArtworkFound=${counts.eventLevelArtworkFound} rejectedUntrustedURLs=${counts.rejectedUntrustedURLs} providerRequests=${counts.providerRequests}`,
  )

  return json({
    success: true,
    force,
    counts,
    diagnostics: nbaDiagnostics ? { nba: nbaDiagnostics } : undefined,
  })
})
