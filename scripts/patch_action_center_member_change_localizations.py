#!/usr/bin/env python3
"""Localization for Team membership / role / Administrator Action Center copy."""
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
XCSTRINGS = ROOT / "GameOn" / "Localizable.xcstrings"
SUPPORTED = ["en", "es", "fr", "pt", "de", "it", "pl", "ru", "sq", "zh-Hans", "nl"]


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def locs(translations: dict[str, str]) -> dict:
    return {lang: unit(translations.get(lang, translations["en"])) for lang in SUPPORTED}


ENTRIES: dict[str, dict[str, str]] = {
    "action_center_team_notif_removed_title": {
        "en": "Removed from Team",
        "es": "Eliminado del equipo",
        "fr": "Retiré de l’équipe",
        "pt": "Removido da equipe",
        "de": "Aus dem Team entfernt",
        "it": "Rimosso dalla squadra",
        "pl": "Usunięto z drużyny",
        "ru": "Исключены из команды",
        "sq": "U hoqe nga ekipi",
        "zh-Hans": "已移出队伍",
        "nl": "Verwijderd uit team",
    },
    "action_center_team_notif_removed_body_format": {
        "en": "You are no longer a member of %@.",
        "es": "Ya no eres miembro de %@.",
        "fr": "Vous n’êtes plus membre de %@.",
        "pt": "Você não é mais membro de %@.",
        "de": "Du bist kein Mitglied mehr von %@.",
        "it": "Non sei più membro di %@.",
        "pl": "Nie jesteś już członkiem %@.",
        "ru": "Вы больше не участник %@.",
        "sq": "Nuk je më anëtar i %@.",
        "zh-Hans": "你已不再是 %@ 的成员。",
        "nl": "Je bent geen lid meer van %@.",
    },
    "action_center_team_notif_role_title": {
        "en": "Team Role Updated",
        "es": "Rol del equipo actualizado",
        "fr": "Rôle d’équipe mis à jour",
        "pt": "Função da equipe atualizada",
        "de": "Teamrolle aktualisiert",
        "it": "Ruolo della squadra aggiornato",
        "pl": "Zaktualizowano rolę w drużynie",
        "ru": "Роль в команде обновлена",
        "sq": "Roli i ekipit u përditësua",
        "zh-Hans": "队伍角色已更新",
        "nl": "Teamrol bijgewerkt",
    },
    "action_center_team_notif_role_body_format": {
        "en": "You're now a %@ for %@.",
        "es": "Ahora eres %@ en %@.",
        "fr": "Vous êtes désormais %@ pour %@.",
        "pt": "Você agora é %@ em %@.",
        "de": "Du bist jetzt %@ bei %@.",
        "it": "Ora sei %@ per %@.",
        "pl": "Jesteś teraz %@ w %@.",
        "ru": "Теперь вы %@ в %@.",
        "sq": "Tani je %@ për %@.",
        "zh-Hans": "你现在是%@（%@）。",
        "nl": "Je bent nu %@ voor %@.",
    },
    "action_center_team_notif_role_member_body_format": {
        "en": "Your role on %@ is now %@.",
        "es": "Tu rol en %@ ahora es %@.",
        "fr": "Votre rôle dans %@ est désormais %@.",
        "pt": "Sua função em %@ agora é %@.",
        "de": "Deine Rolle bei %@ ist jetzt %@.",
        "it": "Il tuo ruolo in %@ ora è %@.",
        "pl": "Twoja rola w %@ to teraz %@.",
        "ru": "Ваша роль в %@ теперь %@.",
        "sq": "Roli yt në %@ tani është %@.",
        "zh-Hans": "你在 %@ 的角色现在是%@。",
        "nl": "Je rol bij %@ is nu %@.",
    },
    "action_center_team_notif_admin_title": {
        "en": "Team Access Updated",
        "es": "Acceso al equipo actualizado",
        "fr": "Accès à l’équipe mis à jour",
        "pt": "Acesso à equipe atualizado",
        "de": "Teamzugriff aktualisiert",
        "it": "Accesso alla squadra aggiornato",
        "pl": "Zaktualizowano dostęp do drużyny",
        "ru": "Доступ к команде обновлён",
        "sq": "Qasja në ekip u përditësua",
        "zh-Hans": "队伍权限已更新",
        "nl": "Teamtoegang bijgewerkt",
    },
    "action_center_team_notif_admin_granted_body_format": {
        "en": "You can now help manage %@.",
        "es": "Ahora puedes ayudar a gestionar %@.",
        "fr": "Vous pouvez désormais aider à gérer %@.",
        "pt": "Agora você pode ajudar a gerenciar %@.",
        "de": "Du kannst jetzt %@ mitverwalten.",
        "it": "Ora puoi aiutare a gestire %@.",
        "nl": "Je kunt nu helpen %@ te beheren.",
        "pl": "Możesz teraz pomagać w zarządzaniu %@.",
        "ru": "Теперь вы можете помогать управлять %@.",
        "sq": "Tani mund të ndihmosh në menaxhimin e %@.",
        "zh-Hans": "你现在可以协助管理 %@。",
    },
    "action_center_team_notif_admin_removed_body_format": {
        "en": "Your Team Administrator access for %@ was removed.",
        "es": "Se eliminó tu acceso de administrador de equipo para %@.",
        "fr": "Votre accès Administrateur d’équipe pour %@ a été retiré.",
        "pt": "Seu acesso de administrador da equipe %@ foi removido.",
        "de": "Dein Team-Administrator-Zugriff für %@ wurde entfernt.",
        "it": "Il tuo accesso Amministratore squadra per %@ è stato rimosso.",
        "pl": "Usunięto twój dostęp administratora drużyny %@.",
        "ru": "Доступ администратора команды %@ снят.",
        "sq": "Qasja jote e administratorit të ekipit për %@ u hoq.",
        "zh-Hans": "你对 %@ 的队伍管理员权限已移除。",
        "nl": "Je Teambeheerder-toegang voor %@ is verwijderd.",
    },
    "action_center_cta_view_teams": {
        "en": "View Teams",
        "es": "Ver equipos",
        "fr": "Voir les équipes",
        "pt": "Ver equipes",
        "de": "Teams ansehen",
        "it": "Vedi squadre",
        "pl": "Zobacz drużyny",
        "ru": "К командам",
        "sq": "Shiko ekipet",
        "zh-Hans": "查看队伍",
        "nl": "Bekijk teams",
    },
}


def main() -> None:
    data = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    strings = data.setdefault("strings", {})
    for key, translations in ENTRIES.items():
        entry = strings.get(key) or {"extractionState": "manual", "localizations": {}}
        entry["extractionState"] = "manual"
        entry["localizations"] = locs(translations)
        strings[key] = entry
    XCSTRINGS.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"patched {len(ENTRIES)} member-change Action Center keys")


if __name__ == "__main__":
    main()
