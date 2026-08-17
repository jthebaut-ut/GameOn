#!/usr/bin/env python3
"""Localizations for Manage Player Teams rows (member since + open Team)."""
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
    "managed_players_member_since_format": {
        "en": "Member since %@",
        "es": "Miembro desde %@",
        "fr": "Membre depuis %@",
        "pt": "Membro desde %@",
        "de": "Mitglied seit %@",
        "it": "Membro da %@",
        "pl": "Członek od %@",
        "ru": "В команде с %@",
        "sq": "Anëtar që nga %@",
        "zh-Hans": "%@ 加入",
    },
    "managed_players_open_team_a11y": {
        "en": "Opens this Team",
        "es": "Abre este equipo",
        "fr": "Ouvre cette équipe",
        "pt": "Abre esta equipe",
        "de": "Öffnet dieses Team",
        "it": "Apre questa squadra",
        "pl": "Otwiera tę drużynę",
        "ru": "Открывает эту команду",
        "sq": "Hap këtë ekip",
        "zh-Hans": "打开此队伍",
    },
    "managed_players_open_team_unavailable": {
        "en": "This Team isn’t available right now.",
        "es": "Este equipo no está disponible ahora.",
        "fr": "Cette équipe n’est pas disponible pour le moment.",
        "pt": "Esta equipe não está disponível agora.",
        "de": "Dieses Team ist gerade nicht verfügbar.",
        "it": "Questa squadra non è disponibile in questo momento.",
        "pl": "Ta drużyna jest teraz niedostępna.",
        "ru": "Эта команда сейчас недоступна.",
        "sq": "Ky ekip nuk është i disponueshëm tani.",
        "zh-Hans": "此队伍暂时不可用。",
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
