/**
 * Localized APNs alert copy for Fan Team member_left_team.
 * Locales match L10n.supportedLanguages / fangeo_supported_app_locales().
 * No preferred_app_language column exists yet — callers default to "en".
 */

export type PushAlertContent = { title: string; body: string }

const SUPPORTED = [
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

type Locale = (typeof SUPPORTED)[number]

const ROSTER_UPDATE: Record<Locale, string> = {
  en: "%@ roster update",
  es: "Actualización de plantilla de %@",
  fr: "Mise à jour de l’effectif %@",
  pt: "Atualização do elenco %@",
  de: "%@ Kader-Update",
  it: "Aggiornamento rosa %@",
  pl: "Aktualizacja składu %@",
  ru: "Обновление состава %@",
  sq: "Përditësim i listës %@",
  "zh-Hans": "%@ 阵容更新",
}

const LEFT_BODY: Record<Locale, string> = {
  en: "%@ left the team.",
  es: "%@ dejó el equipo.",
  fr: "%@ a quitté l’équipe.",
  pt: "%@ saiu do time.",
  de: "%@ hat das Team verlassen.",
  it: "%@ ha lasciato la squadra.",
  pl: "%@ opuścił(a) drużynę.",
  ru: "%@ покинул(а) команду.",
  sq: "%@ u largua nga ekipi.",
  "zh-Hans": "%@ 已离开队伍。",
}

function normalizeLocale(raw: string | null | undefined): Locale {
  const code = (raw ?? "en").trim()
  const hit = SUPPORTED.find((l) => l.toLowerCase() === code.toLowerCase())
  return hit ?? "en"
}

function applyPlaceholder(template: string, value: string): string {
  return template.replace("%@", value)
}

function sanitizeName(raw: string, fallback: string): string {
  const trimmed = raw.trim()
  if (!trimmed) return fallback
  // Never surface emails / uuid-like tokens in push copy.
  if (trimmed.includes("@") && trimmed.includes(".")) return fallback
  if (/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(trimmed)) {
    return fallback
  }
  return trimmed.length > 48 ? `${trimmed.slice(0, 47)}…` : trimmed
}

export function buildMemberLeftTeamAlert(args: {
  teamName: string
  leftDisplayName: string
  locale?: string | null
}): PushAlertContent {
  const locale = normalizeLocale(args.locale)
  const team = sanitizeName(args.teamName, "Team")
  const person = sanitizeName(args.leftDisplayName, "A teammate")
  return {
    title: applyPlaceholder(ROSTER_UPDATE[locale], team),
    body: applyPlaceholder(LEFT_BODY[locale], person),
  }
}

export function memberLeftTeamAlertSelfTest(): void {
  const en = buildMemberLeftTeamAlert({
    teamName: "JT",
    leftDisplayName: "Enea Rrokaj",
    locale: "en",
  })
  if (en.title !== "JT roster update") throw new Error("title_mismatch")
  if (en.body !== "Enea Rrokaj left the team.") throw new Error("body_mismatch")

  const es = buildMemberLeftTeamAlert({
    teamName: "JT",
    leftDisplayName: "Enea",
    locale: "es",
  })
  if (!es.body.includes("Enea") || !es.body.includes("equipo")) {
    throw new Error("es_body_mismatch")
  }
}
