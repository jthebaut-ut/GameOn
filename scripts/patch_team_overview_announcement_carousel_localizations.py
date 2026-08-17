#!/usr/bin/env python3
"""Localizations for Team Overview announcement carousel + Clear."""
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
    "team_announcement_overview_clear": {
        "en": "Clear",
        "es": "Quitar",
        "fr": "Effacer",
        "pt": "Limpar",
        "de": "Ausblenden",
        "it": "Rimuovi",
        "pl": "Ukryj",
        "ru": "Скрыть",
        "sq": "Fshi",
        "zh-Hans": "清除",
        "nl": "Wissen",
    },
    "team_announcement_overview_clear_a11y": {
        "en": "Clear announcement",
        "es": "Quitar anuncio",
        "fr": "Effacer l’annonce",
        "pt": "Limpar anúncio",
        "de": "Ankündigung ausblenden",
        "it": "Rimuovi annuncio",
        "pl": "Ukryj ogłoszenie",
        "ru": "Скрыть объявление",
        "sq": "Fshi njoftimin",
        "zh-Hans": "清除公告",
        "nl": "Aankondiging wissen",
    },
    "team_announcement_overview_position_format": {
        "en": "%lld of %lld",
        "es": "%lld de %lld",
        "fr": "%lld sur %lld",
        "pt": "%lld de %lld",
        "de": "%lld von %lld",
        "it": "%lld di %lld",
        "pl": "%lld z %lld",
        "ru": "%lld из %lld",
        "sq": "%lld nga %lld",
        "zh-Hans": "%lld / %lld",
        "nl": "%lld van %lld",
    },
    "team_announcement_overview_position_a11y_format": {
        "en": "Announcement %lld of %lld",
        "es": "Anuncio %lld de %lld",
        "fr": "Annonce %lld sur %lld",
        "pt": "Anúncio %lld de %lld",
        "de": "Ankündigung %lld von %lld",
        "it": "Annuncio %lld di %lld",
        "pl": "Ogłoszenie %lld z %lld",
        "ru": "Объявление %lld из %lld",
        "sq": "Njoftimi %lld nga %lld",
        "zh-Hans": "公告第 %lld 条，共 %lld 条",
        "nl": "Aankondiging %lld van %lld",
    },
    "team_announcement_overview_swipe_a11y_hint": {
        "en": "Swipe left or right for other announcements. Double-tap to open.",
        "es": "Desliza a la izquierda o derecha para otros anuncios. Toca dos veces para abrir.",
        "fr": "Balayez à gauche ou à droite pour les autres annonces. Touchez deux fois pour ouvrir.",
        "pt": "Deslize para a esquerda ou direita para outros anúncios. Toque duas vezes para abrir.",
        "de": "Wische nach links oder rechts für weitere Ankündigungen. Doppeltippen zum Öffnen.",
        "it": "Scorri a sinistra o destra per altri annunci. Tocca due volte per aprire.",
        "pl": "Przesuń w lewo lub prawo, by zobaczyć inne ogłoszenia. Dwukrotne stuknięcie otwiera.",
        "ru": "Смахните влево или вправо для других объявлений. Двойное касание открывает.",
        "sq": "Rrëshqit majtas ose djathtas për njoftime të tjera. Prek dy herë për të hapur.",
        "zh-Hans": "左右滑动查看其他公告。点两下打开。",
        "nl": "Veeg naar links of rechts voor andere aankondigingen. Dubbeltik om te openen.",
    },
}


def main() -> None:
    data = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    strings = data.setdefault("strings", {})
    for key, translations in ENTRIES.items():
        entry = strings.setdefault(key, {})
        entry["localizations"] = locs(translations)
    XCSTRINGS.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Patched {len(ENTRIES)} keys into {XCSTRINGS}")


if __name__ == "__main__":
    main()
