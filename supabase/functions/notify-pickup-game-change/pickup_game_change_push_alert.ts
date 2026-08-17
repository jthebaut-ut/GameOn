/**
 * Authoritative APNs title/body for pickup edit/cancel/create events.
 * Built only from `pickup_game_update_events` payload + optional Team context
 * (never client-supplied copy).
 */

export type PickupGameChangeUpdateEvent = {
  change_kinds?: string[] | null
  payload?: Record<string, unknown> | null
}

/** Optional Team-linked context resolved server-side from fan_team_game_links. */
export type TeamEventPushContext = {
  teamId: string
  teamName: string
  eventTitle: string
  gameFormat: string
  logoURL?: string | null
}

/** High-level push classification for schedule/location/cancel/create. */
export type PickupGameChangeClass =
  | "created"
  | "cancelled"
  | "time_and_location_changed"
  | "time_changed"
  | "location_changed"
  | "other"

function asString(value: unknown): string {
  return typeof value === "string" ? value.trim() : ""
}

function shortPlace(place: string, maxLen = 52): string {
  const trimmed = place.trim()
  if (!trimmed) return ""
  if (trimmed.length <= maxLen) return trimmed
  return `${trimmed.slice(0, Math.max(1, maxLen - 1)).trimEnd()}…`
}

export function formatStartForPush(raw: string): string {
  if (!raw) return ""
  const date = new Date(raw)
  if (Number.isNaN(date.getTime())) return ""
  try {
    const datePart = new Intl.DateTimeFormat("en-US", {
      weekday: "short",
      month: "short",
      day: "numeric",
    }).format(date)
    const timePart = new Intl.DateTimeFormat("en-US", {
      hour: "numeric",
      minute: "2-digit",
    }).format(date)
    return `${datePart} at ${timePart}`
  } catch {
    return ""
  }
}

/** Compact date for create bodies: "Aug 20 at 6:30 PM" (no weekday). */
export function formatStartForPushCompact(raw: string, locale = "en"): string {
  if (!raw) return ""
  const date = new Date(raw)
  if (Number.isNaN(date.getTime())) return ""
  const intlLocale = intlLocaleFor(locale)
  try {
    const datePart = new Intl.DateTimeFormat(intlLocale, {
      month: "short",
      day: "numeric",
    }).format(date)
    const timePart = new Intl.DateTimeFormat(intlLocale, {
      hour: "numeric",
      minute: "2-digit",
    }).format(date)
    const at = atWord(locale)
    return at ? `${datePart} ${at} ${timePart}` : `${datePart} ${timePart}`
  } catch {
    return ""
  }
}

const SUPPORTED_LOCALES = [
  "en",
  "es",
  "fr",
  "pt",
  "de",
  "it",
  "pl",
  "ru",
  "sq",
  "zh-Hans",
] as const

type PushLocale = (typeof SUPPORTED_LOCALES)[number]
type LocaleTable = Record<PushLocale, string>

export function normalizePushLocale(raw?: string | null): PushLocale {
  const code = (raw ?? "en").trim()
  if ((SUPPORTED_LOCALES as readonly string[]).includes(code)) return code as PushLocale
  if (code.toLowerCase() === "pt-br" || code.toLowerCase() === "pt_br") return "pt"
  if (code.toLowerCase() === "zh" || code.toLowerCase().startsWith("zh-")) return "zh-Hans"
  if (code.toLowerCase() === "nl") return "en" // not in FanGeo L10n yet
  return "en"
}

function intlLocaleFor(locale: string): string {
  const n = normalizePushLocale(locale)
  if (n === "zh-Hans") return "zh-CN"
  return n
}

const VS_WORD: LocaleTable = {
  en: "vs",
  es: "vs",
  fr: "vs",
  pt: "vs",
  de: "vs",
  it: "vs",
  pl: "vs",
  ru: "vs",
  sq: "kundër",
  "zh-Hans": "对",
}

const AT_WORD: LocaleTable = {
  en: "at",
  es: "a las",
  fr: "à",
  pt: "às",
  de: "um",
  it: "alle",
  pl: "o",
  ru: "в",
  sq: "në",
  "zh-Hans": "",
}

const NEW_GAME_TITLE: LocaleTable = {
  en: "%@ · New Game",
  es: "%@ · Nuevo partido",
  fr: "%@ · Nouveau match",
  pt: "%@ · Novo jogo",
  de: "%@ · Neues Spiel",
  it: "%@ · Nuova partita",
  pl: "%@ · Nowy mecz",
  ru: "%@ · Новая игра",
  sq: "%@ · Ndeshje e re",
  "zh-Hans": "%@ · 新比赛",
}

const NEW_SCRIMMAGE_TITLE: LocaleTable = {
  en: "%@ · New Scrimmage",
  es: "%@ · Nueva scrimmage",
  fr: "%@ · Nouveau scrimmage",
  pt: "%@ · Novo treino coletivo",
  de: "%@ · Neues Scrimmage",
  it: "%@ · Nuova amichevole",
  pl: "%@ · Nowy sparing",
  ru: "%@ · Новая товарищеская игра",
  sq: "%@ · Scrimmage e re",
  "zh-Hans": "%@ · 新对抗赛",
}

/** "%@" = team name, second "%@" = event type label (Practice, Meeting, …). */
const NEW_EVENT_TITLE: LocaleTable = {
  en: "%@ · New %@",
  es: "%@ · Nuevo %@",
  fr: "%@ · Nouveau %@",
  pt: "%@ · Novo %@",
  de: "%@ · Neu: %@",
  it: "%@ · Nuovo %@",
  pl: "%@ · Nowy %@",
  ru: "%@ · Новое: %@",
  sq: "%@ · I ri: %@",
  "zh-Hans": "%@ · 新 %@",
}

const BODY_EVENT_WHEN: LocaleTable = {
  en: "%@ scheduled for %@.",
  es: "%@ programado para %@.",
  fr: "%@ prévu pour %@.",
  pt: "%@ marcado para %@.",
  de: "%@ geplant für %@.",
  it: "%@ programmato per %@.",
  pl: "%@ zaplanowane na %@.",
  ru: "%@ назначено на %@.",
  sq: "%@ është planifikuar për %@.",
  "zh-Hans": "%@ 安排在 %@。",
}

const BODY_EVENT_NO_WHEN: LocaleTable = {
  en: "%@ was added to the Team Schedule.",
  es: "%@ se añadió al calendario del equipo.",
  fr: "%@ a été ajouté au calendrier de l’équipe.",
  pt: "%@ foi adicionado à agenda da equipe.",
  de: "%@ wurde zum Teamplan hinzugefügt.",
  it: "%@ è stato aggiunto al calendario della squadra.",
  pl: "%@ dodano do harmonogramu drużyny.",
  ru: "%@ добавлено в расписание команды.",
  sq: "%@ u shtua në orarin e ekipit.",
  "zh-Hans": "%@ 已添加到球队赛程。",
}

const BODY_MATCHUP_WHEN: LocaleTable = {
  en: "%@ — %@",
  es: "%@ — %@",
  fr: "%@ — %@",
  pt: "%@ — %@",
  de: "%@ — %@",
  it: "%@ — %@",
  pl: "%@ — %@",
  ru: "%@ — %@",
  sq: "%@ — %@",
  "zh-Hans": "%@ — %@",
}

const BODY_FALLBACK_WHEN: LocaleTable = {
  en: "%@ game scheduled for %@",
  es: "Partido de %@ programado para %@",
  fr: "Match %@ prévu pour %@",
  pt: "Jogo de %@ marcado para %@",
  de: "%@-Spiel geplant für %@",
  it: "Partita di %@ programmata per %@",
  pl: "Mecz %@ zaplanowany na %@",
  ru: "Игра %@ назначена на %@",
  sq: "Ndeshja e %@ është planifikuar për %@",
  "zh-Hans": "%@ 比赛安排在 %@",
}

const BODY_FALLBACK_NO_WHEN: LocaleTable = {
  en: "%@ game was added to the Team Schedule.",
  es: "Se añadió un partido de %@ al calendario del equipo.",
  fr: "Un match %@ a été ajouté au calendrier de l’équipe.",
  pt: "Um jogo de %@ foi adicionado à agenda da equipe.",
  de: "Ein %@-Spiel wurde zum Teamplan hinzugefügt.",
  it: "Una partita di %@ è stata aggiunta al calendario della squadra.",
  pl: "Dodano mecz %@ do harmonogramu drużyny.",
  ru: "Игра %@ добавлена в расписание команды.",
  sq: "Një ndeshje e %@ u shtua në orarin e ekipit.",
  "zh-Hans": "%@ 比赛已添加到球队赛程。",
}

function applyOne(template: string, value: string): string {
  return template.replace("%@", value)
}

function applyTwo(template: string, a: string, b: string): string {
  return template.replace("%@", a).replace("%@", b)
}

function atWord(locale: string): string {
  return AT_WORD[normalizePushLocale(locale)]
}

/** Competitive Team formats that enqueue team_game_created (server helper mirror). */
export function isFanTeamGameCreatePushFormat(gameFormat: string): boolean {
  const raw = gameFormat.trim().toLowerCase()
  return raw === "league_game" || raw === "tournament_game" || raw === "match" || raw === "scrimmage"
}

/** All Team Schedule formats that enqueue create APNs (excludes announcement). */
export function isFanTeamScheduleCreatePushFormat(gameFormat: string): boolean {
  const raw = gameFormat.trim().toLowerCase()
  return (
    isFanTeamGameCreatePushFormat(raw)
    || raw === "practice"
    || raw === "tryout"
    || raw === "clinic"
    || raw === "team_meeting"
    || raw === "other"
    || raw === "pickup"
  )
}

function isCompetitiveFormat(gameFormat: string): boolean {
  return isFanTeamGameCreatePushFormat(gameFormat)
}

function vsWord(locale: string): string {
  return VS_WORD[normalizePushLocale(locale)]
}

/** Matchup from Team name + opponent_name (never invent opponent from free-text title). */
export function teamGameCreatedMatchup(
  teamName: string,
  opponent: string,
  locale = "en",
): string {
  const home = teamName.trim()
  const away = opponent.trim()
  if (!home || !away) return ""
  return `${home} ${vsWord(locale)} ${away}`
}

export function buildTeamGameCreatedPushAlert(args: {
  teamName: string
  gameFormat: string
  opponent?: string | null
  matchup?: string | null
  afterStart?: string | null
  locale?: string | null
}): { title: string; body: string } {
  const locale = normalizePushLocale(args.locale)
  const teamName = args.teamName.trim() || "Team"
  const format = (args.gameFormat ?? "").trim().toLowerCase()

  // Non-competitive schedule creates (practice / meeting / …) use type-aware copy.
  if (!isFanTeamGameCreatePushFormat(format)) {
    return buildTeamEventCreatedPushAlert({
      teamName,
      gameFormat: format,
      afterStart: args.afterStart,
      locale,
    })
  }

  const titleTemplate = format === "scrimmage" ? NEW_SCRIMMAGE_TITLE[locale] : NEW_GAME_TITLE[locale]
  const title = applyOne(titleTemplate, teamName)

  const opponent = (args.opponent ?? "").trim()
  const matchupFromFields = teamGameCreatedMatchup(teamName, opponent, locale)
  const matchup = matchupFromFields || (args.matchup ?? "").trim()
  const when = formatStartForPushCompact(args.afterStart ?? "", locale)
    || formatStartForPush(args.afterStart ?? "")

  if (matchup && when) {
    return { title, body: applyTwo(BODY_MATCHUP_WHEN[locale], matchup, when) }
  }
  if (matchup) {
    return { title, body: matchup }
  }
  if (when) {
    return { title, body: applyTwo(BODY_FALLBACK_WHEN[locale], teamName, when) }
  }
  return { title, body: applyOne(BODY_FALLBACK_NO_WHEN[locale], teamName) }
}

/** Practice / tryout / clinic / meeting / other create alert. */
export function buildTeamEventCreatedPushAlert(args: {
  teamName: string
  gameFormat: string
  afterStart?: string | null
  eventTitle?: string | null
  locale?: string | null
}): { title: string; body: string } {
  const locale = normalizePushLocale(args.locale)
  const teamName = args.teamName.trim() || "Team"
  const typeLabel = teamEventTypeLabel(args.gameFormat, args.eventTitle ?? "")
  const title = applyTwo(NEW_EVENT_TITLE[locale], teamName, typeLabel)
  const when = formatStartForPushCompact(args.afterStart ?? "", locale)
    || formatStartForPush(args.afterStart ?? "")
  if (when) {
    return { title, body: applyTwo(BODY_EVENT_WHEN[locale], typeLabel, when) }
  }
  return { title, body: applyOne(BODY_EVENT_NO_WHEN[locale], typeLabel) }
}

const ANNOUNCEMENT_TITLE: LocaleTable = {
  en: "%@ · Announcement",
  es: "%@ · Anuncio",
  fr: "%@ · Annonce",
  pt: "%@ · Anúncio",
  de: "%@ · Ankündigung",
  it: "%@ · Annuncio",
  pl: "%@ · Ogłoszenie",
  ru: "%@ · Объявление",
  sq: "%@ · Njoftim",
  "zh-Hans": "%@ · 公告",
}

export function buildTeamAnnouncementPushAlert(args: {
  teamName: string
  title: string
  bodyPreview?: string | null
  locale?: string | null
}): { title: string; body: string } {
  const locale = normalizePushLocale(args.locale)
  const teamName = args.teamName.trim() || "Team"
  const headline = args.title.trim() || teamName
  const preview = (args.bodyPreview ?? "").trim()
  const title = applyOne(ANNOUNCEMENT_TITLE[locale], teamName)
  if (preview) {
    const clipped = preview.length > 120 ? `${preview.slice(0, 117).trimEnd()}…` : preview
    return { title, body: `${headline} — ${clipped}` }
  }
  return { title, body: headline }
}

/** Human label for Team event type tokens (not hardcoded “game”). */
export function teamEventTypeLabel(gameFormat: string, fallbackTitle: string): string {
  const raw = gameFormat.trim().toLowerCase()
  const map: Record<string, string> = {
    league_game: "League Game",
    tournament_game: "Tournament Game",
    practice: "Practice",
    scrimmage: "Scrimmage",
    tryout: "Tryout",
    clinic: "Clinic / Camp",
    match: "Match",
    pickup: "Pickup",
    team_meeting: "Team Meeting",
    other: "Event",
    announcement: "Announcement",
  }
  if (raw && map[raw]) return map[raw]
  const title = fallbackTitle.trim()
  return title || "Event"
}

/** Short noun for titles: "Game", "Practice", … */
export function teamEventTypeShortNoun(gameFormat: string): string {
  const raw = gameFormat.trim().toLowerCase()
  const map: Record<string, string> = {
    league_game: "Game",
    tournament_game: "Game",
    match: "Game",
    scrimmage: "Scrimmage",
    practice: "Practice",
    tryout: "Tryout",
    clinic: "Clinic",
    team_meeting: "Meeting",
    other: "Event",
    pickup: "Game",
    announcement: "Announcement",
  }
  return map[raw] || "Event"
}

export function classifyPickupGameChange(
  event: PickupGameChangeUpdateEvent,
): PickupGameChangeClass {
  const kinds = new Set((event.change_kinds ?? []).map((k) => k.toLowerCase()))
  const payload = event.payload ?? {}
  const afterStatus = asString(payload.after_status).toLowerCase()
  const beforeStatus = asString(payload.before_status).toLowerCase()
  const notificationType = asString(payload.notification_type).toLowerCase()
  const isCancellation =
    (beforeStatus !== "removed" && afterStatus === "removed")
    || (beforeStatus !== "cancelled" && afterStatus === "cancelled")
    || (beforeStatus !== "canceled" && afterStatus === "canceled")
    || payload.is_cancellation === true

  if (
    kinds.has("created")
    || payload.is_team_event_created === true
    || payload.is_team_game_created === true
    || payload.is_team_announcement === true
    || notificationType === "team_game_created"
    || notificationType === "team_event_created"
    || notificationType === "team_announcement"
  ) {
    return "created"
  }
  if (isCancellation) return "cancelled"

  const timeChanged = kinds.has("start") || kinds.has("end")
  const locationChanged = kinds.has("location")
  if (timeChanged && locationChanged) return "time_and_location_changed"
  if (timeChanged) return "time_changed"
  if (locationChanged) return "location_changed"
  return "other"
}

function eventDisplayName(
  event: PickupGameChangeUpdateEvent,
  team: TeamEventPushContext | null,
): string {
  if (team) {
    const fromTitle = team.eventTitle.trim()
    if (fromTitle) return fromTitle
    return teamEventTypeLabel(team.gameFormat, "")
  }
  return asString(event.payload?.title) || "Pickup game"
}

/** Prefer Team + opponent_name matchup; fall back to type label (not free-text title inventing opponent). */
function teamMemberFacingName(
  event: PickupGameChangeUpdateEvent,
  team: TeamEventPushContext,
): string {
  const opponent = asString(event.payload?.after_opponent)
  if (opponent && isCompetitiveFormat(team.gameFormat)) {
    return teamGameCreatedMatchup(team.teamName, opponent, "en")
  }
  const title = team.eventTitle.trim() || asString(event.payload?.title)
  if (title) return title
  return teamEventTypeLabel(team.gameFormat, "")
}

const JOIN_REQUEST_TITLE: LocaleTable = {
  en: "Your request to join",
  es: "Tu solicitud para unirte",
  fr: "Votre demande pour rejoindre",
  pt: "Seu pedido para participar",
  de: "Deine Beitrittsanfrage",
  it: "La tua richiesta di unirti",
  pl: "Twoja prośba o dołączenie",
  ru: "Ваша заявка на участие",
  sq: "Kërkesa jote për t’u bashkuar",
  "zh-Hans": "你的加入申请",
}

const JOIN_REQUEST_APPROVED: LocaleTable = {
  en: "%@ was approved.",
  es: "%@ fue aprobada.",
  fr: "%@ a été approuvée.",
  pt: "%@ foi aprovado.",
  de: "%@ wurde genehmigt.",
  it: "%@ è stata approvata.",
  pl: "%@ została zatwierdzona.",
  ru: "%@ одобрена.",
  sq: "%@ u miratua.",
  "zh-Hans": "%@ 已获批准。",
}

const JOIN_REQUEST_DECLINED: LocaleTable = {
  en: "%@ was declined.",
  es: "%@ fue rechazada.",
  fr: "%@ a été refusée.",
  pt: "%@ foi recusado.",
  de: "%@ wurde abgelehnt.",
  it: "%@ è stata rifiutata.",
  pl: "%@ została odrzucona.",
  ru: "%@ отклонена.",
  sq: "%@ u refuzua.",
  "zh-Hans": "%@ 已被拒绝。",
}

export function isJoinRequestDecisionType(notificationType: string): boolean {
  const type = notificationType.trim().toLowerCase()
  return type === "join_request_approved" || type === "join_request_rejected"
}

export function isTeamEventScoreNotificationType(notificationType: string): boolean {
  const type = notificationType.trim().toLowerCase()
  return type === "team_event_scored" || type === "team_event_final"
}

export function teamEventScorerAttributionKind(sport: string | null | undefined): string | null {
  const hay = String(sport ?? "").trim().toLowerCase()
  if (!hay) return null
  if (/(volleyball|badminton|tennis|padel|pickleball|ping.?pong|running|track|climbing|paragliding|hang.?glid|paramotor|cycling|swim|ski|golf|esport|bowling|dance|ballet|boxing|mma|ufc|wrestl)/.test(hay)) {
    return null
  }
  if (/(soccer|futsal|futbol)/.test(hay)) return "goal"
  if (/(nhl|\bhockey\b)/.test(hay)) return "goal"
  if (/lacrosse/.test(hay)) return "goal"
  if (/(nba|wnba|basketball)/.test(hay)) return "score"
  if (/(baseball|mlb|softball)/.test(hay)) return "run"
  if (/(nfl|american.?football)/.test(hay) || hay === "football") return "touchdown_or_score"
  return null
}

function scorerNameFromPayload(payload: Record<string, unknown>): string {
  return asString(payload.scorer_display_name)
    || asString(payload.scorer_display_name_snapshot)
    || asString(payload.player_display_name)
}

export function buildTeamEventScorePushTitle(input: {
  notificationType: string
  teamName: string
  scorerName?: string | null
  attributionKind?: string | null
  scoreTitle?: string | null
}): string {
  const type = String(input.notificationType ?? "").trim().toLowerCase()
  if (type === "team_event_final") return "Final"
  const name = String(input.scorerName ?? "").trim()
  const kind = String(input.attributionKind ?? "").trim().toLowerCase()
  if (name) {
    if (kind === "goal") return `Goal — ${name}`
    if (kind === "run") return `Run scored — ${name}`
    if (kind === "score") return `${name} scored`
    if (kind === "touchdown_or_score") return `Score — ${name}`
  }
  const explicit = String(input.scoreTitle ?? "").trim()
  if (explicit) return explicit
  const team = String(input.teamName ?? "").trim() || "Team"
  return `${team} scored`
}

function teamScoreLineFromPayload(
  payload: Record<string, unknown>,
  team: TeamEventPushContext | null,
): string {
  const explicit = asString(payload.score_line)
  if (explicit) return explicit
  const teamName = team?.teamName?.trim() || asString(payload.team_name) || "Team"
  const opponent = asString(payload.after_opponent) || "Opponent"
  const teamScore = Number(payload.team_score)
  const opponentScore = Number(payload.opponent_score)
  if (!Number.isFinite(teamScore) || !Number.isFinite(opponentScore)) {
    return `${teamName} vs ${opponent}`
  }
  return `${teamName} ${teamScore} – ${opponentScore} ${opponent}`
}

export function buildTeamEventScorePushAlert(
  payload: Record<string, unknown>,
  team: TeamEventPushContext | null = null,
): { title: string; body: string } {
  const type = asString(payload.notification_type).toLowerCase()
  const teamName = team?.teamName?.trim() || asString(payload.team_name) || "Team"
  const body = teamScoreLineFromPayload(payload, team)
  const kind = asString(payload.scorer_attribution_kind)
    || teamEventScorerAttributionKind(asString(payload.sport))
    || null
  const title = buildTeamEventScorePushTitle({
    notificationType: type,
    teamName,
    scorerName: scorerNameFromPayload(payload),
    attributionKind: kind,
    scoreTitle: asString(payload.score_title) || asString(payload.title),
  })
  return { title, body }
}

/** Build alert from authoritative event row only (ignore client-supplied copy). */
export function buildPickupGameChangePushAlert(
  event: PickupGameChangeUpdateEvent,
  team: TeamEventPushContext | null = null,
  locale: string | null = "en",
): { title: string; body: string } {
  const payload = event.payload ?? {}
  const notificationType = asString(payload.notification_type).toLowerCase()
  if (isTeamEventScoreNotificationType(notificationType)) {
    return buildTeamEventScorePushAlert(payload, team)
  }
  if (isJoinRequestDecisionType(notificationType)) {
    const loc = normalizePushLocale(locale)
    const eventName =
      asString(payload.title) || eventDisplayName(event, team) || "Event"
    const bodyTemplate = notificationType === "join_request_approved"
      ? JOIN_REQUEST_APPROVED[loc]
      : JOIN_REQUEST_DECLINED[loc]
    return {
      title: JOIN_REQUEST_TITLE[loc],
      body: applyOne(bodyTemplate, eventName),
    }
  }
  const titleName = eventDisplayName(event, team)
  const afterStart = formatStartForPush(asString(payload.after_start))
  const afterStartCompact = formatStartForPushCompact(asString(payload.after_start), locale ?? "en")
  const afterLocation = shortPlace(asString(payload.after_location))
  const beforePlayers = Number(payload.before_players_needed ?? NaN)
  const afterPlayers = Number(payload.after_players_needed ?? NaN)
  const changeClass = classifyPickupGameChange(event)
  const teamName = team?.teamName?.trim() || asString(payload.team_name)
  const typeNoun = team ? teamEventTypeShortNoun(team.gameFormat) : "Game"
  const memberName = team ? teamMemberFacingName(event, team) : titleName
  const confirmAgain = " Please confirm your attendance again."
  const typeLabel = team
    ? teamEventTypeLabel(team.gameFormat || asString(payload.game_format), memberName)
    : typeNoun
  const identityLine = teamName
    ? teamEventPushIdentityLine(teamName, memberName)
    : ""
  const beforeStartCompact = formatStartForPushCompact(
    asString(payload.before_start),
    locale ?? "en",
  )
  const beforeLocation = shortPlace(asString(payload.before_location))
  const beforeOpponent = asString(payload.before_opponent)
  const afterOpponent = asString(payload.after_opponent)

  if (changeClass === "created" && teamName) {
    const format = team?.gameFormat || asString(payload.game_format)
    if (
      asString(payload.notification_type) === "team_announcement"
      || payload.is_team_announcement === true
      || format.trim().toLowerCase() === "announcement"
    ) {
      return buildTeamAnnouncementPushAlert({
        teamName,
        title: asString(payload.title) || team?.eventTitle || "",
        bodyPreview: asString(payload.description_preview),
        locale,
      })
    }
    return buildTeamGameCreatedPushAlert({
      teamName,
      gameFormat: format,
      opponent: asString(payload.after_opponent),
      matchup: asString(payload.matchup),
      afterStart: asString(payload.after_start),
      locale,
    })
  }

  if (changeClass === "cancelled") {
    if (teamName) {
      const when = afterStartCompact || afterStart
      return {
        title: `${typeLabel} cancelled`,
        body: when ? `${identityLine}\n${when}` : identityLine,
      }
    }
    if (afterStart) {
      return {
        title: "Game cancelled",
        body: `${titleName} on ${afterStart} was cancelled.`,
      }
    }
    return {
      title: "Game cancelled",
      body: `${titleName} was cancelled.`,
    }
  }

  if (changeClass === "time_and_location_changed") {
    if (teamName) {
      const lines = [identityLine]
      const startArrow = pushArrow(beforeStartCompact || asString(payload.before_start), afterStartCompact || afterStart)
      if (startArrow) lines.push(startArrow)
      const locArrow = pushArrow(beforeLocation, afterLocation)
      if (locArrow) lines.push(locArrow)
      return {
        title: `${typeLabel} updated`,
        body: `${lines.filter(Boolean).join("\n")}${confirmAgain}`,
      }
    }
    if (afterStart && afterLocation) {
      return {
        title: "Schedule & location changed",
        body: `${titleName} now starts ${afterStart} at ${afterLocation}.`,
      }
    }
    return {
      title: "Schedule & location changed",
      body: `${titleName} has a new time and location.`,
    }
  }

  if (changeClass === "time_changed") {
    if (teamName) {
      const startArrow = pushArrow(
        beforeStartCompact || asString(payload.before_start),
        afterStartCompact || afterStart,
      )
      const when = startArrow || afterStartCompact || afterStart
      return {
        title: `${typeLabel} time changed`,
        body: when ? `${identityLine}\n${when}${confirmAgain}` : `${identityLine}${confirmAgain}`,
      }
    }
    if (afterStart) {
      return {
        title: "Schedule changed",
        body: `${titleName} now starts ${afterStart}.`,
      }
    }
    return {
      title: "Schedule changed",
      body: `${titleName} has a new schedule.`,
    }
  }

  if (changeClass === "location_changed") {
    if (teamName) {
      const locArrow = pushArrow(beforeLocation, afterLocation) || afterLocation
      return {
        title: `${typeLabel} location changed`,
        body: locArrow ? `${identityLine}\n${locArrow}` : identityLine,
      }
    }
    if (afterLocation) {
      return {
        title: "Location changed",
        body: `${titleName} moved to ${afterLocation}.`,
      }
    }
    return {
      title: "Location changed",
      body: `${titleName} moved to a new location.`,
    }
  }

  const kinds = new Set((event.change_kinds ?? []).map((k) => k.toLowerCase()))
  if (kinds.has("capacity") && Number.isFinite(beforePlayers) && Number.isFinite(afterPlayers)) {
    return {
      title: teamName ? `${teamName} · ${typeNoun} Updated` : "Pickup game updated",
      body: `${memberName} capacity changed from ${beforePlayers} to ${afterPlayers}.`,
    }
  }
  if (kinds.has("opponent") && teamName) {
    const oppArrow = pushArrow(beforeOpponent, afterOpponent) || afterOpponent
    return {
      title: `${typeLabel} opponent changed`,
      body: oppArrow ? `${identityLine}\n${oppArrow}` : identityLine,
    }
  }
  return {
    title: teamName ? `${typeLabel} updated` : "Pickup game updated",
    body: teamName ? identityLine : `${memberName} was updated.`,
  }
}

function teamEventPushIdentityLine(teamName: string, eventName: string): string {
  const team = teamName.trim()
  const event = eventName.trim()
  if (team && event && team.toLowerCase() !== event.toLowerCase()) {
    return `${team} · ${event}`
  }
  return team || event
}

function pushArrow(before: string, after: string): string {
  const oldValue = before.trim()
  const newValue = after.trim()
  if (oldValue && newValue && oldValue !== newValue) return `${oldValue} → ${newValue}`
  return newValue || oldValue
}
