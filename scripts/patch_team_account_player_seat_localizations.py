#!/usr/bin/env python3
"""Localization for account access vs player seat (Team Overview / Manage)."""
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
    "team_overview_players_from_your_account": {
        "en": "Players from Your Account",
        "es": "Jugadores de tu cuenta",
        "fr": "Joueurs de votre compte",
        "pt": "Jogadores da sua conta",
        "de": "Spieler deines Kontos",
        "it": "Giocatori del tuo account",
        "nl": "Spelers van je account",
        "pl": "Zawodnicy z Twojego konta",
        "ru": "Игроки вашего аккаунта",
        "sq": "Lojtarët nga llogaria juaj",
        "zh-Hans": "你账户下的球员",
    },
    "team_overview_players_from_your_account_helper": {
        "en": "Choose which players from your account are members of this Team. You do not need to include yourself unless you are playing.",
        "es": "Elige qué jugadores de tu cuenta son miembros de este equipo. No hace falta incluirte a ti si no juegas.",
        "fr": "Choisissez quels joueurs de votre compte font partie de cette équipe. Vous n’avez pas besoin de vous inclure si vous ne jouez pas.",
        "pt": "Escolha quais jogadores da sua conta são membros desta equipe. Não precisa se incluir se você não joga.",
        "de": "Wähle, welche Spieler deines Kontos Mitglieder dieses Teams sind. Dich selbst musst du nur hinzufügen, wenn du mitspielst.",
        "it": "Scegli quali giocatori del tuo account sono membri di questa squadra. Non serve includerti se non giochi.",
        "nl": "Kies welke spelers van je account lid zijn van dit team. Je hoeft jezelf niet toe te voegen tenzij je meespeelt.",
        "pl": "Wybierz, którzy zawodnicy z Twojego konta należą do tej drużyny. Nie musisz dodawać siebie, jeśli nie grasz.",
        "ru": "Выберите, какие игроки вашего аккаунта состоят в этой команде. Себя добавлять не нужно, если вы не играете.",
        "sq": "Zgjidhni cilët lojtarë të llogarisë suaj janë anëtarë të kësaj ekipi. Nuk duhet të përfshiheni nëse nuk luani.",
        "zh-Hans": "选择你账户下哪些球员加入此队伍。如果你本人不参赛，不必勾选自己。",
    },
    "team_player_membership_manage_helper": {
        "en": "Choose which players from your account are members of this Team. You do not need to include yourself unless you are playing. Turning off Myself keeps your Team access.",
        "es": "Elige qué jugadores de tu cuenta son miembros. Desactivar “Yo” no elimina tu acceso al equipo.",
        "fr": "Choisissez les joueurs de votre compte. Désactiver « Moi » conserve votre accès à l’équipe.",
        "pt": "Escolha os jogadores da sua conta. Desativar “Eu” mantém seu acesso à equipe.",
        "de": "Wähle Spieler deines Kontos. „Ich“ auszuschalten behält deinen Teamzugang.",
        "it": "Scegli i giocatori del tuo account. Disattivare “Io” mantiene l’accesso alla squadra.",
        "nl": "Kies spelers van je account. Myself uitzetten behoudt je teamtoegang.",
        "pl": "Wybierz zawodników z konta. Wyłączenie „Ja” zachowuje dostęp do drużyny.",
        "ru": "Выберите игроков аккаунта. Отключение «Я» сохраняет доступ к команде.",
        "sq": "Zgjidhni lojtarët e llogarisë. Çaktivizimi i “Unë” ruan aksesin në ekip.",
        "zh-Hans": "选择账户下的球员。关闭“我自己”仍保留队伍访问权限。",
    },
    "team_player_membership_manage_section_header": {
        "en": "Players on This Team",
        "es": "Jugadores en este equipo",
        "fr": "Joueurs de cette équipe",
        "pt": "Jogadores nesta equipe",
        "de": "Spieler in diesem Team",
        "it": "Giocatori in questa squadra",
        "nl": "Spelers in dit team",
        "pl": "Zawodnicy w tej drużynie",
        "ru": "Игроки этой команды",
        "sq": "Lojtarët në këtë ekip",
        "zh-Hans": "本队球员",
    },
    "team_player_membership_remove_myself_confirm_title": {
        "en": "Remove yourself as a player?",
        "es": "¿Quitar tu puesto de jugador?",
        "fr": "Vous retirer comme joueur ?",
        "pt": "Remover você como jogador?",
        "de": "Dich als Spieler entfernen?",
        "it": "Rimuoverti come giocatore?",
        "nl": "Jezelf als speler verwijderen?",
        "pl": "Usunąć siebie jako zawodnika?",
        "ru": "Убрать себя как игрока?",
        "sq": "Të hiqesh si lojtar?",
        "zh-Hans": "将自己从球员名单移除？",
    },
    "team_player_membership_remove_myself_confirm_message": {
        "en": "You’ll keep Team access to manage your players, but you won’t appear on the roster or lineup as a player.",
        "es": "Conservarás el acceso al equipo para gestionar a tus jugadores, pero no aparecerás en la plantilla ni en la alineación.",
        "fr": "Vous gardez l’accès à l’équipe pour gérer vos joueurs, mais vous n’apparaîtrez plus dans l’effectif ni la composition.",
        "pt": "Você mantém o acesso à equipe para gerenciar seus jogadores, mas não aparecerá no elenco nem na escalação.",
        "de": "Du behältst Teamzugang für deine Spieler, erscheinst aber nicht mehr im Kader oder in der Aufstellung.",
        "it": "Mantieni l’accesso alla squadra per gestire i tuoi giocatori, ma non comparirai in rosa o formazione.",
        "nl": "Je houdt teamtoegang om spelers te beheren, maar verschijnt niet meer op de selectie of opstelling.",
        "pl": "Zachowasz dostęp do drużyny, ale nie będziesz widoczny na liście zawodników ani w składzie.",
        "ru": "Доступ к команде сохранится, но вы не будете в составе и расстановке как игрок.",
        "sq": "Do të ruani aksesin për të menaxhuar lojtarët, por nuk do të shfaqeni në listë apo formacion.",
        "zh-Hans": "你仍可访问队伍并管理球员，但不会作为球员出现在名单或阵容中。",
    },
    "team_player_membership_remove_myself_action": {
        "en": "Remove Myself as Player",
        "es": "Quitar mi puesto de jugador",
        "fr": "Me retirer comme joueur",
        "pt": "Remover-me como jogador",
        "de": "Mich als Spieler entfernen",
        "it": "Rimuovimi come giocatore",
        "nl": "Verwijder mezelf als speler",
        "pl": "Usuń mnie jako zawodnika",
        "ru": "Убрать меня как игрока",
        "sq": "Hiqmë si lojtar",
        "zh-Hans": "移除我的球员身份",
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
    # Keep legacy key pointing at the new title for older call sites / tests.
    strings["team_overview_your_players_on_team"] = {
        "extractionState": "manual",
        "localizations": locs(ENTRIES["team_overview_players_from_your_account"]),
    }
    XCSTRINGS.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Patched {len(ENTRIES)} keys (+ legacy alias) into {XCSTRINGS}")


if __name__ == "__main__":
    main()
