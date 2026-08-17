#!/usr/bin/env python3
"""Localization for the single Team Administrator toggle."""
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
XCSTRINGS = ROOT / "GameOn" / "Localizable.xcstrings"
SUPPORTED = ["en", "es", "fr", "pt", "de", "it", "pl", "ru", "sq", "zh-Hans", "nl"]


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def locs(translations: dict[str, str]) -> dict:
    return {lang: unit(translations[lang]) for lang in SUPPORTED if lang in translations}


ENTRIES: dict[str, dict[str, str]] = {
    "fan_team_administrator_title": {
        "en": "Team Administrator",
        "es": "Administrador del equipo",
        "fr": "Administrateur d’équipe",
        "pt": "Administrador da equipe",
        "de": "Team-Administrator",
        "it": "Amministratore della squadra",
        "nl": "Teambeheerder",
        "pl": "Administrator drużyny",
        "ru": "Администратор команды",
        "sq": "Administrator i ekipit",
        "zh-Hans": "队伍管理员",
    },
    "fan_team_administrator_help": {
        "en": "Allows this member to help manage the Team.",
        "es": "Permite a este miembro ayudar a gestionar el equipo.",
        "fr": "Permet à ce membre d’aider à gérer l’équipe.",
        "pt": "Permite que este membro ajude a gerenciar a equipe.",
        "de": "Erlaubt diesem Mitglied, bei der Teamverwaltung zu helfen.",
        "it": "Consente a questo membro di aiutare a gestire la squadra.",
        "nl": "Laat dit lid helpen het Team te beheren.",
        "pl": "Pozwala temu członkowi pomagać w zarządzaniu drużyną.",
        "ru": "Позволяет участнику помогать управлять командой.",
        "sq": "Lejon këtë anëtar të ndihmojë në menaxhimin e ekipit.",
        "zh-Hans": "允许该成员协助管理队伍。",
    },
    "fan_team_administrator_footer": {
        "en": "Team Administrators can create and edit events, publish announcements, invite members, manage rosters and lineups, manage players, edit Team information, and moderate Team Chat. The Team Owner always has full control and can remove this permission at any time.",
        "es": "Los administradores pueden crear y editar eventos, publicar anuncios, invitar miembros, gestionar plantillas y alineaciones, gestionar jugadores, editar la información del equipo y moderar el chat. El propietario siempre tiene el control total y puede quitar este permiso en cualquier momento.",
        "fr": "Les administrateurs peuvent créer et modifier des événements, publier des annonces, inviter des membres, gérer les effectifs et compositions, gérer les joueurs, modifier les informations d’équipe et modérer le chat. Le propriétaire conserve le contrôle total et peut retirer cette autorisation à tout moment.",
        "pt": "Administradores podem criar e editar eventos, publicar avisos, convidar membros, gerenciar elencos e escalações, gerenciar jogadores, editar informações da equipe e moderar o chat. O proprietário sempre tem controle total e pode remover esta permissão a qualquer momento.",
        "de": "Team-Administratoren können Events erstellen und bearbeiten, Ankündigungen veröffentlichen, Mitglieder einladen, Kader und Aufstellungen verwalten, Spieler verwalten, Teaminformationen bearbeiten und den Team-Chat moderieren. Der Team-Inhaber behält die volle Kontrolle und kann diese Berechtigung jederzeit entziehen.",
        "it": "Gli amministratori possono creare e modificare eventi, pubblicare annunci, invitare membri, gestire rose e formazioni, gestire i giocatori, modificare le informazioni della squadra e moderare la chat. Il proprietario ha sempre il controllo completo e può revocare questa autorizzazione in qualsiasi momento.",
        "nl": "Teambeheerders kunnen evenementen maken en bewerken, aankondigingen publiceren, leden uitnodigen, selecties en opstellingen beheren, spelers beheren, Teaminformatie bewerken en Teamchat modereren. De Team-eigenaar houdt altijd de volledige controle en kan deze toestemming op elk moment intrekken.",
        "pl": "Administratorzy mogą tworzyć i edytować wydarzenia, publikować ogłoszenia, zapraszać członków, zarządzać składem i ustawieniami, zarządzać zawodnikami, edytować informacje o drużynie i moderować czat. Właściciel zawsze ma pełną kontrolę i może w każdej chwili odebrać to uprawnienie.",
        "ru": "Администраторы могут создавать и изменять события, публиковать объявления, приглашать участников, управлять составом и расстановками, управлять игроками, редактировать информацию о команде и модерировать чат. Владелец всегда сохраняет полный контроль и может отозвать это право в любой момент.",
        "sq": "Administratorët mund të krijojnë dhe ndryshojnë ngjarje, të publikojnë njoftime, të ftojnë anëtarë, të menaxhojnë listat dhe formacionet, të menaxhojnë lojtarët, të ndryshojnë informacionin e ekipit dhe të moderojnë bisedën. Pronari gjithmonë ka kontroll të plotë dhe mund ta heqë këtë leje në çdo kohë.",
        "zh-Hans": "队伍管理员可以创建和编辑活动、发布公告、邀请成员、管理名单和阵容、管理球员、编辑队伍信息以及管理队伍聊天。队伍所有者始终拥有完全控制权，并可随时移除此权限。",
    },
}


def main() -> None:
    data = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    strings = data.setdefault("strings", {})
    for key, translations in ENTRIES.items():
        strings[key] = {
            "extractionState": "manual",
            "localizations": locs(translations),
        }
    XCSTRINGS.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Patched {len(ENTRIES)} keys into {XCSTRINGS}")


if __name__ == "__main__":
    main()
