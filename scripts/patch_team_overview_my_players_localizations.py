#!/usr/bin/env python3
"""Localizations for Team Overview 'My Players on This Team'."""
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
    "team_overview_my_players_on_team": {
        "en": "My Players on This Team",
        "es": "Mis jugadores en este equipo",
        "fr": "Mes joueurs dans cette équipe",
        "pt": "Meus jogadores nesta equipe",
        "de": "Meine Spieler in diesem Team",
        "it": "I miei giocatori in questa squadra",
        "pl": "Moi zawodnicy w tej drużynie",
        "ru": "Мои игроки в этой команде",
        "sq": "Lojtarët e mi në këtë ekip",
        "zh-Hans": "本队中的我的球员",
        "nl": "Mijn spelers in dit team",
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
    print(f"Patched {len(ENTRIES)} keys into Localizable.xcstrings")


if __name__ == "__main__":
    main()
