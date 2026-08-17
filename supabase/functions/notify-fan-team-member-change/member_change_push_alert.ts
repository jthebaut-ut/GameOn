/**
 * Localized APNs alert copy for Fan Team member-change events:
 *   player_number_set/changed/removed, preferred_position_set/changed/removed,
 *   team_role_changed, removed_from_event, added_back_to_event, removed_from_team.
 *
 * Locales match L10n.supportedLanguages / fangeo_supported_app_locales().
 * No preferred_app_language column exists yet — callers default to "en".
 */

import { formatStartForPush, teamEventTypeLabel } from "../notify-pickup-game-change/pickup_game_change_push_alert.ts"

export type PushAlertContent = { title: string; body: string }

export type MemberChangeKind =
  | "player_number_set"
  | "player_number_changed"
  | "player_number_removed"
  | "preferred_position_set"
  | "preferred_position_changed"
  | "preferred_position_removed"
  | "team_role_changed"
  | "removed_from_event"
  | "added_back_to_event"
  | "removed_from_team"
  | "team_admin_granted"
  | "team_admin_removed"

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
type LocaleTable = Record<Locale, string>

const TITLE_PLAYER_INFO: LocaleTable = {
  en: "%@ player information updated",
  es: "Información de jugador de %@ actualizada",
  fr: "Informations du joueur de %@ mises à jour",
  pt: "Informações do jogador de %@ atualizadas",
  de: "%@ Spielerinformationen aktualisiert",
  it: "Informazioni giocatore di %@ aggiornate",
  pl: "Zaktualizowano informacje o zawodniku %@",
  ru: "Информация об игроке %@ обновлена",
  sq: "Informacioni i lojtarit të %@ u përditësua",
  "zh-Hans": "%@ 球员信息已更新",
}

const TITLE_ROLE: LocaleTable = {
  en: "Team Role Updated",
  es: "Rol del equipo actualizado",
  fr: "Rôle d’équipe mis à jour",
  pt: "Função da equipe atualizada",
  de: "Teamrolle aktualisiert",
  it: "Ruolo della squadra aggiornato",
  pl: "Zaktualizowano rolę w drużynie",
  ru: "Роль в команде обновлена",
  sq: "Roli i ekipit u përditësua",
  "zh-Hans": "队伍角色已更新",
}

const TITLE_MEMBERSHIP_REMOVED: LocaleTable = {
  en: "Removed from Team",
  es: "Eliminado del equipo",
  fr: "Retiré de l’équipe",
  pt: "Removido da equipe",
  de: "Aus dem Team entfernt",
  it: "Rimosso dalla squadra",
  pl: "Usunięto z drużyny",
  ru: "Исключены из команды",
  sq: "U hoqe nga ekipi",
  "zh-Hans": "已移出队伍",
}

const TITLE_ADMIN: LocaleTable = {
  en: "Team Access Updated",
  es: "Acceso al equipo actualizado",
  fr: "Accès à l’équipe mis à jour",
  pt: "Acesso à equipe atualizado",
  de: "Teamzugriff aktualisiert",
  it: "Accesso alla squadra aggiornato",
  pl: "Zaktualizowano dostęp do drużyny",
  ru: "Доступ к команде обновлён",
  sq: "Qasja në ekip u përditësua",
  "zh-Hans": "队伍权限已更新",
}

const TITLE_EVENT: LocaleTable = {
  en: "%@ event update",
  es: "Actualización de evento de %@",
  fr: "Mise à jour d’événement %@",
  pt: "Atualização de evento de %@",
  de: "%@ Termin-Update",
  it: "Aggiornamento evento %@",
  pl: "Aktualizacja wydarzenia %@",
  ru: "Обновление события %@",
  sq: "Përditësim eventi i %@",
  "zh-Hans": "%@ 活动更新",
}

const TITLE_MEMBERSHIP: LocaleTable = {
  en: "%@ membership update",
  es: "Actualización de membresía de %@",
  fr: "Mise à jour d’adhésion %@",
  pt: "Atualização de associação de %@",
  de: "%@ Mitgliedschafts-Update",
  it: "Aggiornamento iscrizione %@",
  pl: "Aktualizacja członkostwa w %@",
  ru: "Обновление членства в %@",
  sq: "Përditësim anëtarësimi në %@",
  "zh-Hans": "%@ 会员更新",
}

const PLAYER_NUMBER_SET_BODY: LocaleTable = {
  en: "Your number is now #%@.",
  es: "Tu número ahora es #%@.",
  fr: "Votre numéro est désormais le #%@.",
  pt: "Seu número agora é o #%@.",
  de: "Deine Nummer ist jetzt #%@.",
  it: "Il tuo numero ora è #%@.",
  pl: "Twój numer to teraz #%@.",
  ru: "Ваш номер теперь #%@.",
  sq: "Numri yt tani është #%@.",
  "zh-Hans": "你的号码现在是 #%@。",
}

const PLAYER_NUMBER_CHANGED_BODY: LocaleTable = {
  en: "Your number changed to #%@.",
  es: "Tu número cambió a #%@.",
  fr: "Votre numéro a changé pour le #%@.",
  pt: "Seu número mudou para o #%@.",
  de: "Deine Nummer wurde auf #%@ geändert.",
  it: "Il tuo numero è cambiato in #%@.",
  pl: "Twój numer zmienił się na #%@.",
  ru: "Ваш номер изменён на #%@.",
  sq: "Numri yt ndryshoi në #%@.",
  "zh-Hans": "你的号码已更改为 #%@。",
}

const PLAYER_NUMBER_REMOVED_BODY: LocaleTable = {
  en: "Your player number was removed.",
  es: "Se eliminó tu número de jugador.",
  fr: "Votre numéro de joueur a été retiré.",
  pt: "Seu número de jogador foi removido.",
  de: "Deine Spielernummer wurde entfernt.",
  it: "Il tuo numero di maglia è stato rimosso.",
  pl: "Twój numer zawodnika został usunięty.",
  ru: "Ваш игровой номер был удалён.",
  sq: "Numri yt i lojtarit u hoq.",
  "zh-Hans": "你的球员号码已被移除。",
}

const PREFERRED_POSITION_SET_BODY: LocaleTable = {
  en: "Your position is now %@.",
  es: "Tu posición ahora es %@.",
  fr: "Votre poste est désormais %@.",
  pt: "Sua posição agora é %@.",
  de: "Deine Position ist jetzt %@.",
  it: "La tua posizione ora è %@.",
  pl: "Twoja pozycja to teraz %@.",
  ru: "Ваша позиция теперь %@.",
  sq: "Pozicioni yt tani është %@.",
  "zh-Hans": "你的位置现在是 %@。",
}

const PREFERRED_POSITION_CHANGED_BODY: LocaleTable = {
  en: "Your position changed to %@.",
  es: "Tu posición cambió a %@.",
  fr: "Votre poste a changé pour %@.",
  pt: "Sua posição mudou para %@.",
  de: "Deine Position wurde auf %@ geändert.",
  it: "La tua posizione è cambiata in %@.",
  pl: "Twoja pozycja zmieniła się na %@.",
  ru: "Ваша позиция изменена на %@.",
  sq: "Pozicioni yt ndryshoi në %@.",
  "zh-Hans": "你的位置已更改为 %@。",
}

const PREFERRED_POSITION_REMOVED_BODY: LocaleTable = {
  en: "Your position was removed.",
  es: "Se eliminó tu posición.",
  fr: "Votre poste a été retiré.",
  pt: "Sua posição foi removida.",
  de: "Deine Position wurde entfernt.",
  it: "La tua posizione è stata rimossa.",
  pl: "Twoja pozycja została usunięta.",
  ru: "Ваша позиция была удалена.",
  sq: "Pozicioni yt u hoq.",
  "zh-Hans": "你的位置已被移除。",
}

const TEAM_ROLE_CHANGED_BODY: LocaleTable = {
  en: "You're now a %@ for %@.",
  es: "Ahora eres %@ en %@.",
  fr: "Vous êtes désormais %@ pour %@.",
  pt: "Você agora é %@ em %@.",
  de: "Du bist jetzt %@ bei %@.",
  it: "Ora sei %@ per %@.",
  pl: "Jesteś teraz %@ w %@.",
  ru: "Теперь вы %@ в %@.",
  sq: "Tani je %@ për %@.",
  "zh-Hans": "你现在是%@（%@）。",
}

const TEAM_ROLE_MEMBER_BODY: LocaleTable = {
  en: "Your role on %@ is now Member.",
  es: "Tu rol en %@ ahora es Miembro.",
  fr: "Votre rôle dans %@ est désormais Membre.",
  pt: "Sua função em %@ agora é Membro.",
  de: "Deine Rolle bei %@ ist jetzt Mitglied.",
  it: "Il tuo ruolo in %@ ora è Membro.",
  pl: "Twoja rola w %@ to teraz Członek.",
  ru: "Ваша роль в %@ теперь Участник.",
  sq: "Roli yt në %@ tani është Anëtar.",
  "zh-Hans": "你在 %@ 的角色现在是成员。",
}

const TEAM_ADMIN_GRANTED_BODY: LocaleTable = {
  en: "You can now help manage %@.",
  es: "Ahora puedes ayudar a gestionar %@.",
  fr: "Vous pouvez désormais aider à gérer %@.",
  pt: "Agora você pode ajudar a gerenciar %@.",
  de: "Du kannst jetzt %@ mitverwalten.",
  it: "Ora puoi aiutare a gestire %@.",
  pl: "Możesz teraz pomagać w zarządzaniu %@.",
  ru: "Теперь вы можете помогать управлять %@.",
  sq: "Tani mund të ndihmosh në menaxhimin e %@.",
  "zh-Hans": "你现在可以协助管理 %@。",
}

const TEAM_ADMIN_REMOVED_BODY: LocaleTable = {
  en: "Your Team Administrator access for %@ was removed.",
  es: "Se eliminó tu acceso de administrador de equipo para %@.",
  fr: "Votre accès Administrateur d’équipe pour %@ a été retiré.",
  pt: "Seu acesso de administrador da equipe %@ foi removido.",
  de: "Dein Team-Administrator-Zugriff für %@ wurde entfernt.",
  it: "Il tuo accesso Amministratore squadra per %@ è stato rimosso.",
  pl: "Usunięto twój dostęp administratora drużyny %@.",
  ru: "Доступ администратора команды %@ снят.",
  sq: "Qasja jote e administratorit të ekipit për %@ u hoq.",
  "zh-Hans": "你对 %@ 的队伍管理员权限已移除。",
}

const REMOVED_FROM_TEAM_BODY: LocaleTable = {
  en: "You are no longer a member of %@.",
  es: "Ya no eres miembro de %@.",
  fr: "Vous n’êtes plus membre de %@.",
  pt: "Você não é mais membro de %@.",
  de: "Du bist kein Mitglied mehr von %@.",
  it: "Non sei più membro di %@.",
  pl: "Nie jesteś już członkiem %@.",
  ru: "Вы больше не участник %@.",
  sq: "Nuk je më anëtar i %@.",
  "zh-Hans": "你已不再是 %@ 的成员。",
}

const REMOVED_FROM_EVENT_BODY: LocaleTable = {
  en: "You were removed from %@.",
  es: "Se te eliminó de %@.",
  fr: "Vous avez été retiré de %@.",
  pt: "Você foi removido de %@.",
  de: "Du wurdest von %@ entfernt.",
  it: "Sei stato rimosso da %@.",
  pl: "Zostałeś usunięty z %@.",
  ru: "Вас исключили из %@.",
  sq: "U hoqe nga %@.",
  "zh-Hans": "你已被移出 %@。",
}

const ADDED_BACK_TO_EVENT_BODY: LocaleTable = {
  en: "You were added back to %@.",
  es: "Se te agregó de nuevo a %@.",
  fr: "Vous avez été réajouté à %@.",
  pt: "Você foi adicionado novamente a %@.",
  de: "Du wurdest wieder zu %@ hinzugefügt.",
  it: "Sei stato riaggiunto a %@.",
  pl: "Zostałeś ponownie dodany do %@.",
  ru: "Вас снова добавили в %@.",
  sq: "U shtove përsëri në %@.",
  "zh-Hans": "你已被重新加入 %@。",
}

function normalizeLocale(raw: string | null | undefined): Locale {
  const code = (raw ?? "en").trim()
  const hit = SUPPORTED.find((l) => l.toLowerCase() === code.toLowerCase())
  return hit ?? "en"
}

function applyPlaceholder(template: string, value: string): string {
  return template.replace("%@", value)
}

function applyTwo(template: string, a: string, b: string): string {
  return template.replace("%@", a).replace("%@", b)
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

function roleDisplayLabel(role: string): string {
  const cleaned = role.trim().toLowerCase().replace(/[_-]+/g, " ")
  if (!cleaned) return "Member"
  return cleaned
    .split(" ")
    .filter(Boolean)
    .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
    .join(" ")
}

function eventSummary(
  gameFormat: string | null | undefined,
  eventTitle: string | null | undefined,
  gameStartAt: string | null | undefined,
): string {
  const label = teamEventTypeLabel(gameFormat ?? "", eventTitle ?? "")
  const start = formatStartForPush(gameStartAt ?? "")
  return start ? `${label} (${start})` : label
}

export interface BuildMemberChangePushAlertArgs {
  kind: string
  teamName: string
  locale?: string | null
  playerNumber?: number | null
  positionCode?: string | null
  role?: string | null
  previousRole?: string | null
  gameFormat?: string | null
  eventTitle?: string | null
  gameStartAt?: string | null
}

export function buildMemberChangePushAlert(args: BuildMemberChangePushAlertArgs): PushAlertContent {
  const locale = normalizeLocale(args.locale)
  const team = sanitizeName(args.teamName ?? "", "Team")

  switch (args.kind as MemberChangeKind) {
    case "player_number_set":
      return {
        title: applyPlaceholder(TITLE_PLAYER_INFO[locale], team),
        body: applyPlaceholder(PLAYER_NUMBER_SET_BODY[locale], String(args.playerNumber ?? "")),
      }
    case "player_number_changed":
      return {
        title: applyPlaceholder(TITLE_PLAYER_INFO[locale], team),
        body: applyPlaceholder(PLAYER_NUMBER_CHANGED_BODY[locale], String(args.playerNumber ?? "")),
      }
    case "player_number_removed":
      return {
        title: applyPlaceholder(TITLE_PLAYER_INFO[locale], team),
        body: PLAYER_NUMBER_REMOVED_BODY[locale],
      }
    case "preferred_position_set":
      return {
        title: applyPlaceholder(TITLE_PLAYER_INFO[locale], team),
        body: applyPlaceholder(PREFERRED_POSITION_SET_BODY[locale], (args.positionCode ?? "").toUpperCase()),
      }
    case "preferred_position_changed":
      return {
        title: applyPlaceholder(TITLE_PLAYER_INFO[locale], team),
        body: applyPlaceholder(PREFERRED_POSITION_CHANGED_BODY[locale], (args.positionCode ?? "").toUpperCase()),
      }
    case "preferred_position_removed":
      return {
        title: applyPlaceholder(TITLE_PLAYER_INFO[locale], team),
        body: PREFERRED_POSITION_REMOVED_BODY[locale],
      }
    case "team_role_changed": {
      const roleToken = (args.role ?? "").trim().toLowerCase().replace(/[\s-]+/g, "_")
      if (!roleToken || roleToken === "member") {
        return {
          title: TITLE_ROLE[locale],
          body: applyPlaceholder(TEAM_ROLE_MEMBER_BODY[locale], team),
        }
      }
      return {
        title: TITLE_ROLE[locale],
        body: applyTwo(
          TEAM_ROLE_CHANGED_BODY[locale],
          roleDisplayLabel(args.role ?? ""),
          team,
        ),
      }
    }
    case "team_admin_granted":
      return {
        title: TITLE_ADMIN[locale],
        body: applyPlaceholder(TEAM_ADMIN_GRANTED_BODY[locale], team),
      }
    case "team_admin_removed":
      return {
        title: TITLE_ADMIN[locale],
        body: applyPlaceholder(TEAM_ADMIN_REMOVED_BODY[locale], team),
      }
    case "removed_from_event":
      return {
        title: applyPlaceholder(TITLE_EVENT[locale], team),
        body: applyPlaceholder(
          REMOVED_FROM_EVENT_BODY[locale],
          eventSummary(args.gameFormat, args.eventTitle, args.gameStartAt),
        ),
      }
    case "added_back_to_event":
      return {
        title: applyPlaceholder(TITLE_EVENT[locale], team),
        body: applyPlaceholder(
          ADDED_BACK_TO_EVENT_BODY[locale],
          eventSummary(args.gameFormat, args.eventTitle, args.gameStartAt),
        ),
      }
    case "removed_from_team":
      return {
        title: TITLE_MEMBERSHIP_REMOVED[locale],
        body: applyPlaceholder(REMOVED_FROM_TEAM_BODY[locale], team),
      }
    default:
      return {
        title: applyPlaceholder(TITLE_MEMBERSHIP[locale], team),
        body: "Your team membership was updated.",
      }
  }
}

export function memberChangePushAlertSelfTest(): void {
  const setAlert = buildMemberChangePushAlert({
    kind: "player_number_set",
    teamName: "JT",
    locale: "en",
    playerNumber: 12,
  })
  if (setAlert.title !== "JT player information updated") throw new Error("player_number_set_title_mismatch")
  if (setAlert.body !== "Your number is now #12.") throw new Error("player_number_set_body_mismatch")

  const removedNumber = buildMemberChangePushAlert({
    kind: "player_number_removed",
    teamName: "JT",
    locale: "en",
  })
  if (removedNumber.body !== "Your player number was removed.") {
    throw new Error("player_number_removed_body_mismatch")
  }

  const positionChanged = buildMemberChangePushAlert({
    kind: "preferred_position_changed",
    teamName: "JT",
    locale: "en",
    positionCode: "cb",
  })
  if (!positionChanged.body.includes("CB")) throw new Error("preferred_position_changed_body_mismatch")

  const roleChanged = buildMemberChangePushAlert({
    kind: "team_role_changed",
    teamName: "JT",
    locale: "en",
    role: "head_coach",
  })
  if (roleChanged.title !== "Team Role Updated") throw new Error("team_role_changed_title_mismatch")
  if (roleChanged.body !== "You're now a Head Coach for JT.") {
    throw new Error("team_role_changed_body_mismatch")
  }

  const roleDemoted = buildMemberChangePushAlert({
    kind: "team_role_changed",
    teamName: "JT",
    locale: "en",
    role: "member",
    previousRole: "manager",
  })
  if (roleDemoted.body !== "Your role on JT is now Member.") {
    throw new Error("team_role_demoted_body_mismatch")
  }

  const adminGranted = buildMemberChangePushAlert({
    kind: "team_admin_granted",
    teamName: "JT",
    locale: "en",
  })
  if (adminGranted.title !== "Team Access Updated") throw new Error("team_admin_granted_title_mismatch")
  if (adminGranted.body !== "You can now help manage JT.") {
    throw new Error("team_admin_granted_body_mismatch")
  }

  const adminRemoved = buildMemberChangePushAlert({
    kind: "team_admin_removed",
    teamName: "JT",
    locale: "en",
  })
  if (adminRemoved.body !== "Your Team Administrator access for JT was removed.") {
    throw new Error("team_admin_removed_body_mismatch")
  }

  const removedFromEvent = buildMemberChangePushAlert({
    kind: "removed_from_event",
    teamName: "JT",
    locale: "en",
    gameFormat: "practice",
    eventTitle: "",
    gameStartAt: "",
  })
  if (removedFromEvent.title !== "JT event update") throw new Error("removed_from_event_title_mismatch")
  if (!removedFromEvent.body.includes("Practice")) throw new Error("removed_from_event_body_mismatch")

  const removedFromTeam = buildMemberChangePushAlert({
    kind: "removed_from_team",
    teamName: "JT",
    locale: "en",
  })
  if (removedFromTeam.title !== "Removed from Team") {
    throw new Error("removed_from_team_title_mismatch")
  }
  if (removedFromTeam.body !== "You are no longer a member of JT.") {
    throw new Error("removed_from_team_body_mismatch")
  }

  const es = buildMemberChangePushAlert({
    kind: "added_back_to_event",
    teamName: "JT",
    locale: "es",
    gameFormat: "scrimmage",
    eventTitle: "",
    gameStartAt: "",
  })
  if (!es.title.includes("JT")) throw new Error("es_added_back_title_mismatch")
  if (!es.body.includes("Se te agregó")) throw new Error("es_added_back_body_mismatch")
}
