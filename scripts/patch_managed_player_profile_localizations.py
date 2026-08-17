#!/usr/bin/env python3
"""Localizations for Manage Player profile redesign (age + member since label)."""
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
    "managed_players_age_format": {
        "en": "Age %lld",
        "es": "Edad %lld",
        "fr": "Âge %lld",
        "pt": "Idade %lld",
        "de": "Alter %lld",
        "it": "Età %lld",
        "pl": "Wiek %lld",
        "ru": "Возраст %lld",
        "sq": "Mosha %lld",
        "zh-Hans": "%lld 岁",
    },
    "managed_players_member_since_label": {
        "en": "Member since",
        "es": "Miembro desde",
        "fr": "Membre depuis",
        "pt": "Membro desde",
        "de": "Mitglied seit",
        "it": "Membro da",
        "pl": "Członek od",
        "ru": "В команде с",
        "sq": "Anëtar që nga",
        "zh-Hans": "加入时间",
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
