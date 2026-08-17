#!/usr/bin/env python3
"""Localization for Team Overview Next Event dashboard empty states."""
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
    "fan_teams_no_upcoming_events": {
        "en": "No Upcoming Events",
        "es": "No hay eventos próximos",
        "fr": "Aucun événement à venir",
        "pt": "Nenhum evento próximo",
        "de": "Keine bevorstehenden Events",
        "it": "Nessun evento in programma",
        "pl": "Brak nadchodzących wydarzeń",
        "ru": "Нет предстоящих событий",
        "sq": "Nuk ka ngjarje të ardhshme",
        "zh-Hans": "暂无即将到来的活动",
    },
    "fan_teams_no_upcoming_events_organizer_body": {
        "en": "Schedule your next practice, game, or team announcement.",
        "es": "Programa tu próximo entrenamiento, partido o anuncio del equipo.",
        "fr": "Planifiez votre prochain entraînement, match ou annonce d’équipe.",
        "pt": "Agende o próximo treino, jogo ou anúncio da equipe.",
        "de": "Plane dein nächstes Training, Spiel oder Team-Announcement.",
        "it": "Programma il prossimo allenamento, partita o annuncio della squadra.",
        "pl": "Zaplanuj następny trening, mecz lub ogłoszenie drużyny.",
        "ru": "Запланируйте следующую тренировку, игру или объявление команды.",
        "sq": "Planifiko stërvitjen, ndeshjen ose njoftimin e radhës të ekipit.",
        "zh-Hans": "安排下一场训练、比赛或队伍公告。",
    },
    "fan_teams_no_upcoming_events_member_body": {
        "en": "Your team doesn’t have anything scheduled yet.",
        "es": "Tu equipo aún no tiene nada programado.",
        "fr": "Votre équipe n’a encore rien de prévu.",
        "pt": "Sua equipe ainda não tem nada agendado.",
        "de": "Dein Team hat noch nichts geplant.",
        "it": "La tua squadra non ha ancora nulla in programma.",
        "pl": "Twoja drużyna nie ma jeszcze nic zaplanowanego.",
        "ru": "У вашей команды пока ничего не запланировано.",
        "sq": "Ekipi yt nuk ka asgjë të planifikuar ende.",
        "zh-Hans": "你的队伍目前还没有安排。",
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
