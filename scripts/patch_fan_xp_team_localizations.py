#!/usr/bin/env python3
"""Fan XP help-table Team rows + section headers (all FanGeo languages)."""
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
    "fan_xp_section_general": {
        "en": "General",
        "es": "General",
        "fr": "Général",
        "pt": "Geral",
        "de": "Allgemein",
        "it": "Generale",
        "pl": "Ogólne",
        "ru": "Общее",
        "sq": "Të përgjithshme",
        "zh-Hans": "通用",
        "nl": "Algemeen",
    },
    "fan_xp_section_pickup": {
        "en": "Pickup",
        "es": "Partidos improvisados",
        "fr": "Matchs improvisés",
        "pt": "Partidas improvisadas",
        "de": "Pickup",
        "it": "Partite pickup",
        "pl": "Pickup",
        "ru": "Пикап",
        "sq": "Pickup",
        "zh-Hans": "临时球局",
        "nl": "Pickup",
    },
    "fan_xp_section_teams": {
        "en": "Teams",
        "es": "Equipos",
        "fr": "Équipes",
        "pt": "Equipas",
        "de": "Teams",
        "it": "Squadre",
        "pl": "Drużyny",
        "ru": "Команды",
        "sq": "Ekipet",
        "zh-Hans": "球队",
        "nl": "Teams",
    },
    "fan_xp_rule_team_created_title": {
        "en": "Create a Team",
        "es": "Crear un equipo",
        "fr": "Créer une équipe",
        "pt": "Criar uma equipe",
        "de": "Ein Team erstellen",
        "it": "Crea una squadra",
        "pl": "Utwórz drużynę",
        "ru": "Создать команду",
        "sq": "Krijo një ekip",
        "zh-Hans": "创建球队",
        "nl": "Maak een team",
    },
    "fan_xp_freq_once_per_team_created": {
        "en": "First 5 Teams you create",
        "es": "Los primeros 5 equipos que crees",
        "fr": "Tes 5 premières équipes créées",
        "pt": "As primeiras 5 equipes que criares",
        "de": "Die ersten 5 Teams, die du erstellst",
        "it": "Le prime 5 squadre che crei",
        "pl": "Pierwsze 5 drużyn, które utworzysz",
        "ru": "Первые 5 созданных тобой команд",
        "sq": "5 ekipet e para që krijon",
        "zh-Hans": "你创建的前 5 支球队",
        "nl": "De eerste 5 teams die je aanmaakt",
    },
    "fan_xp_rule_team_join_player_title": {
        "en": "Join a Team as a player",
        "es": "Unirte a un equipo como jugador",
        "fr": "Rejoindre une équipe comme joueur",
        "pt": "Entrar numa equipe como jogador",
        "de": "Einem Team als Spieler beitreten",
        "it": "Unisciti a una squadra come giocatore",
        "pl": "Dołącz do drużyny jako zawodnik",
        "ru": "Вступить в команду как игрок",
        "sq": "Bashkohu në një ekip si lojtar",
        "zh-Hans": "以球员身份加入球队",
        "nl": "Word speler in een team",
    },
    "fan_xp_freq_once_per_team_as_player": {
        "en": "Once per Team",
        "es": "Una vez por equipo",
        "fr": "Une fois par équipe",
        "pt": "Uma vez por equipe",
        "de": "Einmal pro Team",
        "it": "Una volta per squadra",
        "pl": "Raz na drużynę",
        "ru": "Один раз за команду",
        "sq": "Një herë për ekip",
        "zh-Hans": "每支球队一次",
        "nl": "Eenmaal per team",
    },
    "fan_xp_rule_team_event_created_title": {
        "en": "Create a Team event",
        "es": "Crear un evento de equipo",
        "fr": "Créer un événement d’équipe",
        "pt": "Criar um evento de equipe",
        "de": "Ein Team-Event erstellen",
        "it": "Crea un evento di squadra",
        "pl": "Utwórz wydarzenie drużynowe",
        "ru": "Создать командное событие",
        "sq": "Krijo një event ekipi",
        "zh-Hans": "创建球队活动",
        "nl": "Maak een teamevenement",
    },
    "fan_xp_freq_per_valid_team_event": {
        "en": "Up to 8 valid events per day",
        "es": "Hasta 8 eventos válidos al día",
        "fr": "Jusqu’à 8 événements valides par jour",
        "pt": "Até 8 eventos válidos por dia",
        "de": "Bis zu 8 gültige Events pro Tag",
        "it": "Fino a 8 eventi validi al giorno",
        "pl": "Do 8 prawidłowych wydarzeń dziennie",
        "ru": "До 8 действительных событий в день",
        "sq": "Deri në 8 evente të vlefshme në ditë",
        "zh-Hans": "每天最多 8 场有效活动",
        "nl": "Maximaal 8 geldige evenementen per dag",
    },
    "fan_xp_rule_team_event_completed_player_title": {
        "en": "Complete a Team event",
        "es": "Completar un evento de equipo",
        "fr": "Terminer un événement d’équipe",
        "pt": "Concluir um evento de equipe",
        "de": "Ein Team-Event abschließen",
        "it": "Completa un evento di squadra",
        "pl": "Ukończ wydarzenie drużynowe",
        "ru": "Завершить командное событие",
        "sq": "Përfundo një event ekipi",
        "zh-Hans": "完成一场球队活动",
        "nl": "Rond een teamevenement af",
    },
    "fan_xp_freq_per_completed_team_event_played": {
        "en": "Per completed event you played in",
        "es": "Por cada evento completado en el que jugaste",
        "fr": "Par événement terminé auquel tu as participé",
        "pt": "Por evento concluído em que jogaste",
        "de": "Pro abgeschlossenem Event, an dem du teilgenommen hast",
        "it": "Per ogni evento completato a cui hai partecipato",
        "pl": "Za każde ukończone wydarzenie, w którym grałeś",
        "ru": "За каждое завершённое событие, в котором ты играл",
        "sq": "Për çdo event të përfunduar ku luajte",
        "zh-Hans": "每场你参加并完成的活动",
        "nl": "Per afgerond evenement waarin je speelde",
    },
    "fan_xp_rule_team_event_completed_organizer_title": {
        "en": "Organize a completed Team event",
        "es": "Organizar un evento de equipo completado",
        "fr": "Organiser un événement d’équipe terminé",
        "pt": "Organizar um evento de equipe concluído",
        "de": "Ein abgeschlossenes Team-Event organisieren",
        "it": "Organizza un evento di squadra completato",
        "pl": "Zorganizuj ukończone wydarzenie drużynowe",
        "ru": "Организовать завершённое командное событие",
        "sq": "Organizo një event ekipi të përfunduar",
        "zh-Hans": "组织一场已完成的球队活动",
        "nl": "Organiseer een afgerond teamevenement",
    },
    "fan_xp_freq_per_completed_team_event_organized": {
        "en": "Per completed event organized",
        "es": "Por cada evento completado que organizaste",
        "fr": "Par événement terminé que tu as organisé",
        "pt": "Por evento concluído que organizaste",
        "de": "Pro abgeschlossenem Event, das du organisiert hast",
        "it": "Per ogni evento completato che hai organizzato",
        "pl": "Za każde ukończone wydarzenie, które zorganizowałeś",
        "ru": "За каждое завершённое событие, которое ты организовал",
        "sq": "Për çdo event të përfunduar që organizove",
        "zh-Hans": "每场你组织并完成的活动",
        "nl": "Per afgerond evenement dat je organiseerde",
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
