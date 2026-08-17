#!/usr/bin/env python3
"""Localizations for Team Schedule compact location map preview a11y."""
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
    "team_schedule_map_preview_a11y_format": {
        "en": "Map preview for %@.",
        "es": "Vista previa del mapa de %@.",
        "fr": "Aperçu de la carte pour %@.",
        "pt": "Prévia do mapa de %@.",
        "de": "Kartenvorschau für %@.",
        "it": "Anteprima mappa di %@.",
        "pl": "Podgląd mapy dla %@.",
        "ru": "Предпросмотр карты для %@.",
        "sq": "Parapamja e hartës për %@.",
        "zh-Hans": "%@ 的地图预览。",
        "nl": "Kaartvoorbeeld voor %@.",
    },
    "team_schedule_map_preview_a11y_fallback": {
        "en": "Selected location map preview.",
        "es": "Vista previa del mapa de la ubicación seleccionada.",
        "fr": "Aperçu de la carte du lieu sélectionné.",
        "pt": "Prévia do mapa do local selecionado.",
        "de": "Kartenvorschau des ausgewählten Orts.",
        "it": "Anteprima mappa della posizione selezionata.",
        "pl": "Podgląd mapy wybranej lokalizacji.",
        "ru": "Предпросмотр карты выбранного места.",
        "sq": "Parapamja e hartës së vendndodhjes së zgjedhur.",
        "zh-Hans": "所选地点的地图预览。",
        "nl": "Kaartvoorbeeld van de geselecteerde locatie.",
    },
    "team_schedule_map_preview_a11y_hint": {
        "en": "Double tap to change location.",
        "es": "Toca dos veces para cambiar la ubicación.",
        "fr": "Touchez deux fois pour changer de lieu.",
        "pt": "Toque duas vezes para alterar o local.",
        "de": "Doppeltippen, um den Ort zu ändern.",
        "it": "Tocca due volte per cambiare posizione.",
        "pl": "Dotknij dwukrotnie, aby zmienić lokalizację.",
        "ru": "Дважды нажмите, чтобы изменить место.",
        "sq": "Prek dy herë për të ndryshuar vendndodhjen.",
        "zh-Hans": "轻点两下以更改地点。",
        "nl": "Dubbeltik om de locatie te wijzigen.",
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
    print(f"Patched {len(ENTRIES)} keys into {XCSTRINGS}")


if __name__ == "__main__":
    main()
