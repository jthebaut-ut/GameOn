#!/usr/bin/env python3
"""Localization for Team Overview Your Players + membership manage sheet."""
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
XCSTRINGS = ROOT / "GameOn" / "Localizable.xcstrings"
SUPPORTED = ["en", "es", "fr", "pt", "de", "it", "pl", "ru", "sq", "zh-Hans"]


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def locs(translations: dict[str, str]) -> dict:
    return {lang: unit(translations[lang]) for lang in SUPPORTED if lang in translations}


ENTRIES: dict[str, dict[str, str]] = {
    "team_overview_your_players_on_team": {
        "en": "Your Players on This Team",
        "es": "Tus jugadores en este equipo",
        "fr": "Vos joueurs dans cette équipe",
        "pt": "Seus jogadores nesta equipe",
        "de": "Deine Spieler in diesem Team",
        "it": "I tuoi giocatori in questa squadra",
        "pl": "Twoi zawodnicy w tej drużynie",
        "ru": "Ваши игроки в этой команде",
        "sq": "Lojtarët e tu në këtë ekip",
        "zh-Hans": "你在本队的球员",
    },
    "team_player_membership_manage": {
        "en": "Manage",
        "es": "Administrar",
        "fr": "Gérer",
        "pt": "Gerenciar",
        "de": "Verwalten",
        "it": "Gestisci",
        "pl": "Zarządzaj",
        "ru": "Управлять",
        "sq": "Menaxho",
        "zh-Hans": "管理",
    },
    "team_player_membership_manage_a11y": {
        "en": "Manage players on this Team",
        "es": "Administrar jugadores de este equipo",
        "fr": "Gérer les joueurs de cette équipe",
        "pt": "Gerenciar jogadores desta equipe",
        "de": "Spieler in diesem Team verwalten",
        "it": "Gestisci i giocatori di questa squadra",
        "pl": "Zarządzaj zawodnikami tej drużyny",
        "ru": "Управлять игроками этой команды",
        "sq": "Menaxho lojtarët e këtij ekipi",
        "zh-Hans": "管理本队球员",
    },
    "team_player_membership_manage_title": {
        "en": "Team Player Membership",
        "es": "Membresía de jugadores",
        "fr": "Appartenance des joueurs",
        "pt": "Participação de jogadores",
        "de": "Team-Mitgliedschaft",
        "it": "Appartenenza giocatori",
        "pl": "Członkostwo zawodników",
        "ru": "Членство игроков",
        "sq": "Anëtarësia e lojtarëve",
        "zh-Hans": "队伍球员席位",
    },
    "team_player_membership_status_on_team": {
        "en": "Currently on this Team",
        "es": "Actualmente en este equipo",
        "fr": "Actuellement dans cette équipe",
        "pt": "Atualmente nesta equipe",
        "de": "Derzeit in diesem Team",
        "it": "Attualmente in questa squadra",
        "pl": "Obecnie w tej drużynie",
        "ru": "Сейчас в этой команде",
        "sq": "Aktualisht në këtë ekip",
        "zh-Hans": "目前在本队",
    },
    "team_player_membership_status_not_on_team": {
        "en": "Not on this Team",
        "es": "No está en este equipo",
        "fr": "Pas dans cette équipe",
        "pt": "Não está nesta equipe",
        "de": "Nicht in diesem Team",
        "it": "Non in questa squadra",
        "pl": "Nie w tej drużynie",
        "ru": "Не в этой команде",
        "sq": "Jo në këtë ekip",
        "zh-Hans": "不在本队",
    },
    "team_player_membership_remove_action": {
        "en": "Remove",
        "es": "Quitar",
        "fr": "Retirer",
        "pt": "Remover",
        "de": "Entfernen",
        "it": "Rimuovi",
        "pl": "Usuń",
        "ru": "Удалить",
        "sq": "Hiq",
        "zh-Hans": "移除",
    },
    "team_player_membership_remove_confirm_title_format": {
        "en": "Remove %@ from this Team?",
        "es": "¿Quitar a %@ de este equipo?",
        "fr": "Retirer %@ de cette équipe ?",
        "pt": "Remover %@ desta equipe?",
        "de": "%@ aus diesem Team entfernen?",
        "it": "Rimuovere %@ da questa squadra?",
        "pl": "Usunąć %@ z tej drużyny?",
        "ru": "Удалить %@ из этой команды?",
        "sq": "Të hiqet %@ nga ky ekip?",
        "zh-Hans": "将 %@ 移出本队？",
    },
    "team_player_membership_remove_confirm_message": {
        "en": "This removes only their seat on this Team. The managed player profile is kept, and other Teams are unchanged.",
        "es": "Esto solo quita su lugar en este equipo. El perfil del jugador gestionado se conserva y los demás equipos no cambian.",
        "fr": "Cela retire uniquement sa place dans cette équipe. Le profil du joueur géré est conservé et les autres équipes restent inchangées.",
        "pt": "Isso remove apenas o lugar nesta equipe. O perfil do jogador gerenciado é mantido e as outras equipes não mudam.",
        "de": "Dadurch wird nur der Platz in diesem Team entfernt. Das verwaltete Spielerprofil bleibt erhalten; andere Teams ändern sich nicht.",
        "it": "Questo rimuove solo il posto in questa squadra. Il profilo del giocatore gestito resta e le altre squadre non cambiano.",
        "pl": "To usuwa tylko miejsce w tej drużynie. Profil zarządzanego zawodnika zostaje, a inne drużyny bez zmian.",
        "ru": "Удаляется только место в этой команде. Профиль подопечного игрока сохраняется, другие команды не меняются.",
        "sq": "Kjo heq vetëm vendin në këtë ekip. Profili i lojtarit të menaxhuar ruhet dhe ekipet e tjera nuk ndryshojnë.",
        "zh-Hans": "仅移除其在本队的席位。托管球员资料保留，其他队伍不受影响。",
    },
    "team_player_membership_myself_informational": {
        "en": "Your own Team membership can’t be removed here.",
        "es": "Tu propia membresía del equipo no se puede quitar aquí.",
        "fr": "Votre propre appartenance à l’équipe ne peut pas être retirée ici.",
        "pt": "Sua própria participação na equipe não pode ser removida aqui.",
        "de": "Deine eigene Team-Mitgliedschaft kann hier nicht entfernt werden.",
        "it": "La tua appartenenza alla squadra non può essere rimossa qui.",
        "pl": "Własnego członkostwa w drużynie nie można tu usunąć.",
        "ru": "Собственное членство в команде здесь удалить нельзя.",
        "sq": "Anëtarësia jote në ekip nuk mund të hiqet këtu.",
        "zh-Hans": "不能在此移除你本人的队伍成员身份。",
    },
    "team_player_membership_empty_title": {
        "en": "No managed players yet.",
        "es": "Aún no hay jugadores gestionados.",
        "fr": "Aucun joueur géré pour le moment.",
        "pt": "Ainda não há jogadores gerenciados.",
        "de": "Noch keine verwalteten Spieler.",
        "it": "Non ci sono ancora giocatori gestiti.",
        "pl": "Brak zarządzanych zawodników.",
        "ru": "Пока нет подопечных игроков.",
        "sq": "Nuk ka ende lojtarë të menaxhuar.",
        "zh-Hans": "还没有托管球员。",
    },
    "team_player_membership_empty_body": {
        "en": "Add a managed player, then place them on this Team.",
        "es": "Añade un jugador gestionado y luego colócalo en este equipo.",
        "fr": "Ajoutez un joueur géré, puis placez-le dans cette équipe.",
        "pt": "Adicione um jogador gerenciado e depois coloque-o nesta equipe.",
        "de": "Füge einen verwalteten Spieler hinzu und setze ihn dann in dieses Team.",
        "it": "Aggiungi un giocatore gestito, poi inseriscilo in questa squadra.",
        "pl": "Dodaj zarządzanego zawodnika, a potem umieść go w tej drużynie.",
        "ru": "Добавьте подопечного игрока, затем включите его в эту команду.",
        "sq": "Shto një lojtar të menaxhuar, pastaj vendose në këtë ekip.",
        "zh-Hans": "先添加托管球员，再将其加入本队。",
    },
    "team_player_membership_add_managed_player": {
        "en": "Add Managed Player",
        "es": "Añadir jugador gestionado",
        "fr": "Ajouter un joueur géré",
        "pt": "Adicionar jogador gerenciado",
        "de": "Verwalteten Spieler hinzufügen",
        "it": "Aggiungi giocatore gestito",
        "pl": "Dodaj zarządzanego zawodnika",
        "ru": "Добавить подопечного игрока",
        "sq": "Shto lojtar të menaxhuar",
        "zh-Hans": "添加托管球员",
    },
    "team_player_membership_manage_footer_format": {
        "en": "Add or remove your managed players on %@. Your own membership stays separate.",
        "es": "Añade o quita tus jugadores gestionados en %@. Tu propia membresía se gestiona aparte.",
        "fr": "Ajoutez ou retirez vos joueurs gérés dans %@. Votre propre appartenance reste séparée.",
        "pt": "Adicione ou remova seus jogadores gerenciados em %@. Sua própria participação fica à parte.",
        "de": "Füge verwaltete Spieler zu %@ hinzu oder entferne sie. Deine eigene Mitgliedschaft bleibt getrennt.",
        "it": "Aggiungi o rimuovi i tuoi giocatori gestiti in %@. La tua appartenenza resta separata.",
        "pl": "Dodawaj lub usuwaj zarządzanych zawodników w %@. Twoje własne członkostwo pozostaje osobne.",
        "ru": "Добавляйте или удаляйте подопечных игроков в %@. Ваше собственное членство отдельно.",
        "sq": "Shto ose hiq lojtarët e tu të menaxhuar në %@. Anëtarësia jote mbetet e veçantë.",
        "zh-Hans": "在 %@ 上添加或移除你的托管球员。你本人的成员身份另行处理。",
    },
    "team_player_membership_overview_none_on_team": {
        "en": "None of your managed players are on this Team yet. Tap Manage to add them.",
        "es": "Ninguno de tus jugadores gestionados está aún en este equipo. Toca Administrar para añadirlos.",
        "fr": "Aucun de vos joueurs gérés n’est encore dans cette équipe. Touchez Gérer pour les ajouter.",
        "pt": "Nenhum dos seus jogadores gerenciados está nesta equipe ainda. Toque em Gerenciar para adicioná-los.",
        "de": "Noch keiner deiner verwalteten Spieler ist in diesem Team. Tippe auf Verwalten, um sie hinzuzufügen.",
        "it": "Nessuno dei tuoi giocatori gestiti è ancora in questa squadra. Tocca Gestisci per aggiungerli.",
        "pl": "Żaden z zarządzanych zawodników nie jest jeszcze w tej drużynie. Dotknij Zarządzaj, aby ich dodać.",
        "ru": "Пока ни один подопечный игрок не в этой команде. Нажмите «Управлять», чтобы добавить.",
        "sq": "Asnjë nga lojtarët e tu të menaxhuar nuk është ende në këtë ekip. Trokit Menaxho për t’i shtuar.",
        "zh-Hans": "你的托管球员尚未加入本队。点“管理”添加。",
    },
    "team_player_membership_add_a11y_hint": {
        "en": "Adds this managed player to the Team",
        "es": "Añade este jugador gestionado al equipo",
        "fr": "Ajoute ce joueur géré à l’équipe",
        "pt": "Adiciona este jogador gerenciado à equipe",
        "de": "Fügt diesen verwalteten Spieler dem Team hinzu",
        "it": "Aggiunge questo giocatore gestito alla squadra",
        "pl": "Dodaje tego zarządzanego zawodnika do drużyny",
        "ru": "Добавляет этого подопечного игрока в команду",
        "sq": "Shton këtë lojtar të menaxhuar në ekip",
        "zh-Hans": "将此托管球员加入队伍",
    },
    "team_player_membership_remove_a11y_hint": {
        "en": "Removes this managed player from the Team",
        "es": "Quita este jugador gestionado del equipo",
        "fr": "Retire ce joueur géré de l’équipe",
        "pt": "Remove este jogador gerenciado da equipe",
        "de": "Entfernt diesen verwalteten Spieler aus dem Team",
        "it": "Rimuove questo giocatore gestito dalla squadra",
        "pl": "Usuwa tego zarządzanego zawodnika z drużyny",
        "ru": "Удаляет этого подопечного игрока из команды",
        "sq": "Heq këtë lojtar të menaxhuar nga ekipi",
        "zh-Hans": "将此托管球员移出队伍",
    },
}


def main() -> None:
    data = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    strings = data.setdefault("strings", {})
    for key, translations in ENTRIES.items():
        entry = strings.get(key) or {"extractionState": "manual", "localizations": {}}
        entry["extractionState"] = "manual"
        locs_map = entry.setdefault("localizations", {})
        for lang, payload in locs(translations).items():
            locs_map[lang] = payload
        strings[key] = entry
    XCSTRINGS.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Patched {len(ENTRIES)} keys into {XCSTRINGS}")


if __name__ == "__main__":
    main()
