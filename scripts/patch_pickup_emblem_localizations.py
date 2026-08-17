#!/usr/bin/env python3
"""Standalone Pickup Discover card copy. Does not overwrite existing translations."""
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
XCSTRINGS = ROOT / "GameOn" / "Localizable.xcstrings"
LANGS = ["en", "es", "fr", "pt", "de", "it", "pl", "ru", "sq", "zh-Hans", "nl"]

ENTRIES: dict[str, dict[str, str]] = {
    "discover_pickup_card_format_badge": {
        "en": "Pickup Game",
        "es": "Partido pickup",
        "fr": "Match pickup",
        "pt": "Jogo pickup",
        "de": "Pickup-Spiel",
        "it": "Partita pickup",
        "pl": "Mecz pickup",
        "ru": "Пикап-игра",
        "sq": "Lojë pickup",
        "zh-Hans": "约球比赛",
        "nl": "Pickupwedstrijd",
    },
    "discover_pickup_emblem_started": {
        "en": "Started",
        "es": "Empezó",
        "fr": "Commencé",
        "pt": "Começou",
        "de": "Gestartet",
        "it": "Iniziata",
        "pl": "Rozpoczęty",
        "ru": "Началась",
        "sq": "Filloi",
        "zh-Hans": "已开始",
        "nl": "Gestart",
    },
    "discover_pickup_emblem_live": {
        "en": "LIVE",
        "es": "EN VIVO",
        "fr": "EN DIRECT",
        "pt": "AO VIVO",
        "de": "LIVE",
        "it": "LIVE",
        "pl": "NA ŻYWO",
        "ru": "ЭФИР",
        "sq": "LIVE",
        "zh-Hans": "直播",
        "nl": "LIVE",
    },
    "discover_pickup_emblem_full": {
        "en": "FULL",
        "es": "COMPLETO",
        "fr": "COMPLET",
        "pt": "LOTADO",
        "de": "VOLL",
        "it": "COMPLETO",
        "pl": "PEŁNY",
        "ru": "ПОЛНО",
        "sq": "PLOT",
        "zh-Hans": "已满",
        "nl": "VOL",
    },
    "discover_pickup_emblem_few_spots": {
        "en": "Few Spots",
        "es": "Pocas plazas",
        "fr": "Peu de places",
        "pt": "Poucas vagas",
        "de": "Wenige Plätze",
        "it": "Pochi posti",
        "pl": "Mało miejsc",
        "ru": "Мало мест",
        "sq": "Pak vende",
        "zh-Hans": "名额不多",
        "nl": "Weinig plekken",
    },
    "discover_pickup_emblem_new": {
        "en": "New",
        "es": "Nuevo",
        "fr": "Nouveau",
        "pt": "Novo",
        "de": "Neu",
        "it": "Nuovo",
        "pl": "Nowe",
        "ru": "Новое",
        "sq": "E re",
        "zh-Hans": "新",
        "nl": "Nieuw",
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
    print(f"upserted {len(ENTRIES)} pickup emblem keys")


if __name__ == "__main__":
    main()
