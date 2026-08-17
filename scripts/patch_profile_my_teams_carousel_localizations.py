#!/usr/bin/env python3
"""Localizations for profile My Teams carousel empty state + View All."""
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
    "profile_my_teams_view_all": {
        "en": "View All",
        "es": "Ver todo",
        "fr": "Tout voir",
        "pt": "Ver tudo",
        "de": "Alle anzeigen",
        "it": "Vedi tutto",
        "pl": "Zobacz wszystko",
        "ru": "Смотреть все",
        "sq": "Shiko të gjitha",
        "zh-Hans": "查看全部",
    },
    "profile_my_teams_empty_title": {
        "en": "No Teams Yet",
        "es": "Aún no hay equipos",
        "fr": "Pas encore d’équipes",
        "pt": "Ainda sem equipes",
        "de": "Noch keine Teams",
        "it": "Nessuna squadra ancora",
        "pl": "Brak drużyn",
        "ru": "Пока нет команд",
        "sq": "Ende pa ekipe",
        "zh-Hans": "还没有队伍",
    },
    "profile_my_teams_empty_body": {
        "en": "Join or create your first team.",
        "es": "Únete o crea tu primer equipo.",
        "fr": "Rejoignez ou créez votre première équipe.",
        "pt": "Entre ou crie sua primeira equipe.",
        "de": "Tritt deinem ersten Team bei oder erstelle eines.",
        "it": "Unisciti o crea la tua prima squadra.",
        "pl": "Dołącz lub utwórz swoją pierwszą drużynę.",
        "ru": "Вступите в команду или создайте первую.",
        "sq": "Bashkohuni ose krijoni ekipin tuaj të parë.",
        "zh-Hans": "加入或创建你的第一支队伍。",
    },
    "profile_my_teams_create_team": {
        "en": "Create Team",
        "es": "Crear equipo",
        "fr": "Créer une équipe",
        "pt": "Criar equipe",
        "de": "Team erstellen",
        "it": "Crea squadra",
        "pl": "Utwórz drużynę",
        "ru": "Создать команду",
        "sq": "Krijo ekip",
        "zh-Hans": "创建队伍",
    },
}


def main() -> None:
    data = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    strings = data.setdefault("strings", {})
    for key, translations in ENTRIES.items():
        entry = strings.get(key, {"extractionState": "manual", "localizations": {}})
        entry["extractionState"] = "manual"
        locs_map = entry.setdefault("localizations", {})
        for lang, payload in locs(translations).items():
            locs_map[lang] = payload
        strings[key] = entry
    XCSTRINGS.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Patched {len(ENTRIES)} keys into {XCSTRINGS}")


if __name__ == "__main__":
    main()
