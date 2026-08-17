#!/usr/bin/env python3
"""Inbox Team-event change-row labels and EVENT CREATED / changed-format keys."""
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
XCSTRINGS = ROOT / "GameOn" / "Localizable.xcstrings"
SUPPORTED = ["en", "es", "fr", "pt", "de", "it", "pl", "ru", "sq", "zh-Hans", "nl"]


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def locs(translations: dict[str, str]) -> dict:
    return {lang: unit(translations.get(lang, translations["en"])) for lang in SUPPORTED}


ENTRIES: dict[str, dict[str, str]] = {
    "action_center_badge_event_created": {
        "en": "EVENT CREATED",
        "es": "EVENTO CREADO",
        "fr": "ÉVÉNEMENT CRÉÉ",
        "pt": "EVENTO CRIADO",
        "de": "EVENT ERSTELLT",
        "it": "EVENTO CREATO",
        "pl": "EVENT UTWORZONY",
        "ru": "СОБЫТИЕ СОЗДАНО",
        "sq": "NGJARJA U KRIJUA",
        "zh-Hans": "活动已创建",
        "nl": "EVENEMENT AANGEMAAKT",
    },
    "action_center_badge_event_updated": {
        "en": "EVENT UPDATED",
        "es": "EVENTO ACTUALIZADO",
        "fr": "ÉVÉNEMENT MIS À JOUR",
        "pt": "EVENTO ATUALIZADO",
        "de": "EVENT AKTUALISIERT",
        "it": "EVENTO AGGIORNATO",
        "pl": "EVENT ZAKTUALIZOWANY",
        "ru": "СОБЫТИЕ ОБНОВЛЕНО",
        "sq": "NGJARJA U PËRDITËSUA",
        "zh-Hans": "活动已更新",
        "nl": "EVENEMENT BIJGEWERKT",
    },
    "action_center_badge_event_cancelled": {
        "en": "EVENT CANCELLED",
        "es": "EVENTO CANCELADO",
        "fr": "ÉVÉNEMENT ANNULÉ",
        "pt": "EVENTO CANCELADO",
        "de": "EVENT ABGESAGT",
        "it": "EVENTO ANNULLATO",
        "pl": "EVENT ODWOŁANY",
        "ru": "СОБЫТИЕ ОТМЕНЕНО",
        "sq": "NGJARJA U ANULUA",
        "zh-Hans": "活动已取消",
        "nl": "EVENEMENT GEANNULEERD",
    },
    "action_center_team_notif_changed_format": {
        "en": "%@ changed",
        "es": "%@ cambiado",
        "fr": "%@ modifié",
        "pt": "%@ alterado",
        "de": "%@ geändert",
        "it": "%@ modificato",
        "pl": "Zmieniono: %@",
        "ru": "%@ изменено",
        "sq": "%@ u ndryshua",
        "zh-Hans": "%@已更改",
        "nl": "%@ gewijzigd",
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
    XCSTRINGS.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"patched {len(ENTRIES)} Team-event change Inbox keys")


if __name__ == "__main__":
    main()
