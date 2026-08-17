#!/usr/bin/env python3
"""Add future-ready Team recruiting badge copy. Does not overwrite existing translations."""
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
XCSTRINGS = ROOT / "GameOn" / "Localizable.xcstrings"
LANGS = ["en", "es", "fr", "pt", "de", "it", "pl", "ru", "sq", "zh-Hans", "nl"]

ENTRIES: dict[str, dict[str, str]] = {
    "team_discovery_looking_for_athletes": {
        "en": "Looking for Athletes",
        "es": "Buscando atletas",
        "fr": "Recherche d’athlètes",
        "pt": "Procurando atletas",
        "de": "Athleten gesucht",
        "it": "Cerca atleti",
        "pl": "Szukamy sportowców",
        "ru": "Ищем спортсменов",
        "sq": "Kërkojmë atletë",
        "zh-Hans": "正在招募运动员",
        "nl": "Op zoek naar atleten",
    },
    "team_discovery_looking_for_fans": {
        "en": "Looking for Fans",
        "es": "Buscando aficionados",
        "fr": "Recherche de fans",
        "pt": "Procurando fãs",
        "de": "Fans gesucht",
        "it": "Cerca tifosi",
        "pl": "Szukamy kibiców",
        "ru": "Ищем болельщиков",
        "sq": "Kërkojmë tifozë",
        "zh-Hans": "正在招募粉丝",
        "nl": "Op zoek naar fans",
    },
    "team_discovery_fan_club_open": {
        "en": "Fan Club Open",
        "es": "Fan club abierto",
        "fr": "Fan club ouvert",
        "pt": "Fã-clube aberto",
        "de": "Fanclub offen",
        "it": "Fan club aperto",
        "pl": "Fanklub otwarty",
        "ru": "Фан-клуб открыт",
        "sq": "Fan club i hapur",
        "zh-Hans": "粉丝俱乐部开放",
        "nl": "Fanclub open",
    },
}


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def upsert(strings: dict, key: str, translations: dict[str, str]) -> None:
    entry = strings.get(key, {"extractionState": "manual", "localizations": {}})
    entry["extractionState"] = "manual"
    locs = entry.setdefault("localizations", {})
    for lang in LANGS:
        value = translations.get(lang, translations["en"])
        existing = locs.get(lang, {}).get("stringUnit", {}).get("value")
        if not existing:
            locs[lang] = unit(value)
    strings[key] = entry


def main() -> None:
    data = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    strings = data.setdefault("strings", {})
    for key, translations in ENTRIES.items():
        upsert(strings, key, translations)
    XCSTRINGS.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"upserted {len(ENTRIES)} recruiting badge keys")


if __name__ == "__main__":
    main()
