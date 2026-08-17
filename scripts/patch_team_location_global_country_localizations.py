#!/usr/bin/env python3
"""Localizations for global Team / Pickup location country + region/postal labels."""
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
    "team_location_country": {
        "en": "Country",
        "es": "País",
        "fr": "Pays",
        "pt": "País",
        "de": "Land",
        "it": "Paese",
        "pl": "Kraj",
        "ru": "Страна",
        "sq": "Shteti",
        "zh-Hans": "国家/地区",
        "nl": "Land",
    },
    "team_location_select_country": {
        "en": "Select country",
        "es": "Seleccionar país",
        "fr": "Sélectionner un pays",
        "pt": "Selecionar país",
        "de": "Land auswählen",
        "it": "Seleziona paese",
        "pl": "Wybierz kraj",
        "ru": "Выберите страну",
        "sq": "Zgjidh shtetin",
        "zh-Hans": "选择国家/地区",
        "nl": "Land selecteren",
    },
    "team_location_country_search": {
        "en": "Search countries",
        "es": "Buscar países",
        "fr": "Rechercher un pays",
        "pt": "Pesquisar países",
        "de": "Länder suchen",
        "it": "Cerca paesi",
        "pl": "Szukaj krajów",
        "ru": "Поиск стран",
        "sq": "Kërko shtete",
        "zh-Hans": "搜索国家/地区",
        "nl": "Zoek landen",
    },
    "team_location_country_required": {
        "en": "Select a country.",
        "es": "Selecciona un país.",
        "fr": "Sélectionnez un pays.",
        "pt": "Selecione um país.",
        "de": "Bitte ein Land auswählen.",
        "it": "Seleziona un paese.",
        "pl": "Wybierz kraj.",
        "ru": "Выберите страну.",
        "sq": "Zgjidhni një shtet.",
        "zh-Hans": "请选择国家/地区。",
        "nl": "Selecteer een land.",
    },
    "team_location_region": {
        "en": "State / Province / Region",
        "es": "Estado / provincia / región",
        "fr": "État / province / région",
        "pt": "Estado / província / região",
        "de": "Bundesland / Provinz / Region",
        "it": "Stato / provincia / regione",
        "pl": "Stan / prowincja / region",
        "ru": "Штат / провинция / регион",
        "sq": "Shteti / provinca / rajoni",
        "zh-Hans": "州 / 省 / 地区",
        "nl": "Staat / provincie / regio",
    },
    "team_location_postal": {
        "en": "Postal / ZIP code",
        "es": "Código postal",
        "fr": "Code postal",
        "pt": "Código postal",
        "de": "Postleitzahl",
        "it": "CAP / codice postale",
        "pl": "Kod pocztowy",
        "ru": "Почтовый индекс",
        "sq": "Kodi postar",
        "zh-Hans": "邮政编码",
        "nl": "Postcode",
    },
    # Keep pickup form keys aligned with global wording.
    "pickup_form_state": {
        "en": "State / Province / Region",
        "es": "Estado / provincia / región",
        "fr": "État / province / région",
        "pt": "Estado / província / região",
        "de": "Bundesland / Provinz / Region",
        "it": "Stato / provincia / regione",
        "pl": "Stan / prowincja / region",
        "ru": "Штат / провинция / регион",
        "sq": "Shteti / provinca / rajoni",
        "zh-Hans": "州 / 省 / 地区",
        "nl": "Staat / provincie / regio",
    },
    "pickup_form_zip": {
        "en": "Postal / ZIP code",
        "es": "Código postal",
        "fr": "Code postal",
        "pt": "Código postal",
        "de": "Postleitzahl",
        "it": "CAP / codice postale",
        "pl": "Kod pocztowy",
        "ru": "Почтовый индекс",
        "sq": "Kodi postar",
        "zh-Hans": "邮政编码",
        "nl": "Postcode",
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
