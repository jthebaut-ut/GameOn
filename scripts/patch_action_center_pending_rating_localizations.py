#!/usr/bin/env python3
"""Add Action Center pending-rating localization keys."""
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
XCSTRINGS = ROOT / "GameOn" / "Localizable.xcstrings"
SUPPORTED = ["en", "es", "fr", "pt", "de", "it", "pl", "ru", "sq", "zh-Hans"]


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def locs(en: str, translations: dict[str, str]) -> dict:
    values = {"en": en, **translations}
    return {lang: unit(values[lang]) for lang in SUPPORTED if lang in values}


ENTRIES: dict[str, dict[str, str]] = {
    "action_center_rate_pickup_title": {
        "en": "Rate your pickup game",
        "es": "Valora tu partido pickup",
        "fr": "Notez votre match pickup",
        "pt": "Avalie sua partida pickup",
        "de": "Bewerte dein Pickup-Spiel",
        "it": "Valuta la tua partita pickup",
        "pl": "Oceń swoją grę pickup",
        "ru": "Оцените пикап-игру",
        "sq": "Vlerëso ndeshjen pickup",
        "zh-Hans": "评价这场约球",
    },
    "action_center_rate_organizer_title": {
        "en": "Rate your organizer",
        "es": "Valora a tu organizador",
        "fr": "Notez votre organisateur",
        "pt": "Avalie seu organizador",
        "de": "Bewerte deinen Organisator",
        "it": "Valuta il tuo organizzatore",
        "pl": "Oceń organizatora",
        "ru": "Оцените организатора",
        "sq": "Vlerëso organizatorin",
        "zh-Hans": "评价组织者",
    },
    "action_center_cta_rate_now": {
        "en": "Rate Now",
        "es": "Valorar ahora",
        "fr": "Noter maintenant",
        "pt": "Avaliar agora",
        "de": "Jetzt bewerten",
        "it": "Valuta ora",
        "pl": "Oceń teraz",
        "ru": "Оценить сейчас",
        "sq": "Vlerëso tani",
        "zh-Hans": "立即评价",
    },
    "pickup_rating_pending_status": {
        "en": "Rating pending",
        "es": "Valoración pendiente",
        "fr": "Évaluation en attente",
        "pt": "Avaliação pendente",
        "de": "Bewertung ausstehend",
        "it": "Valutazione in sospeso",
        "pl": "Ocena oczekująca",
        "ru": "Оценка ожидается",
        "sq": "Vlerësimi në pritje",
        "zh-Hans": "待评价",
    },
}


def main() -> None:
    data = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    strings = data.setdefault("strings", {})
    for key, translations in ENTRIES.items():
        en = translations["en"]
        entry = strings.get(key) or {"extractionState": "manual", "localizations": {}}
        entry["extractionState"] = "manual"
        entry["localizations"] = locs(en, {k: v for k, v in translations.items() if k != "en"})
        strings[key] = entry
    XCSTRINGS.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Patched {len(ENTRIES)} keys into {XCSTRINGS}")


if __name__ == "__main__":
    main()
