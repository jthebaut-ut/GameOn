#!/usr/bin/env python3
"""Localizations for Team Detail header Announce shortcut."""
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
    "fan_teams_header_announce": {
        "en": "Announce",
        "es": "Anunciar",
        "fr": "Annoncer",
        "pt": "Anunciar",
        "de": "Ankündigen",
        "it": "Annuncia",
        "pl": "Ogłoś",
        "ru": "Объявить",
        "sq": "Njoftim",
        "zh-Hans": "公告",
        "nl": "Aankondigen",
    },
}


def main() -> None:
    data = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    strings = data.setdefault("strings", {})
    for key, translations in ENTRIES.items():
        entry = strings.setdefault(key, {})
        entry["localizations"] = locs(translations)
        entry.setdefault("extractionState", "manual")
    XCSTRINGS.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Patched {len(ENTRIES)} keys into {XCSTRINGS}")


if __name__ == "__main__":
    main()
