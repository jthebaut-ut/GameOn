#!/usr/bin/env python3
"""Localization for FanGeo Inbox visual redesign (date groups, When/Where, unread a11y)."""
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
XCSTRINGS = ROOT / "GameOn" / "Localizable.xcstrings"
SUPPORTED = ["en", "es", "fr", "pt", "de", "it", "pl", "ru", "sq", "zh-Hans", "nl"]

MINUTE_VALUES = {
    "en": "minute",
    "es": "minuto",
    "fr": "minute",
    "pt": "minuto",
    "de": "Minute",
    "it": "minuto",
    "pl": "minuta",
    "ru": "минута",
    "sq": "minutë",
    "zh-Hans": "分钟",
    "nl": "minuut",
}


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def locs(translations: dict[str, str]) -> dict:
    return {lang: unit(translations.get(lang, translations["en"])) for lang in SUPPORTED}


ENTRIES: dict[str, dict[str, str]] = {
    "action_center_inbox_group_today": {
        "en": "Today",
        "es": "Hoy",
        "fr": "Aujourd’hui",
        "pt": "Hoje",
        "de": "Heute",
        "it": "Oggi",
        "pl": "Dzisiaj",
        "ru": "Сегодня",
        "sq": "Sot",
        "zh-Hans": "今天",
        "nl": "Vandaag",
    },
    "action_center_inbox_group_yesterday": {
        "en": "Yesterday",
        "es": "Ayer",
        "fr": "Hier",
        "pt": "Ontem",
        "de": "Gestern",
        "it": "Ieri",
        "pl": "Wczoraj",
        "ru": "Вчера",
        "sq": "Dje",
        "zh-Hans": "昨天",
        "nl": "Gisteren",
    },
    "action_center_inbox_group_older": {
        "en": "Older",
        "es": "Anteriores",
        "fr": "Plus ancien",
        "pt": "Mais antigas",
        "de": "Älter",
        "it": "Precedenti",
        "pl": "Starsze",
        "ru": "Ранее",
        "sq": "Më të vjetra",
        "zh-Hans": "更早",
        "nl": "Ouder",
    },
    "action_center_inbox_group_days_ago_format": {
        "en": "%lld days ago",
        "es": "hace %lld días",
        "fr": "il y a %lld jours",
        "pt": "há %lld dias",
        "de": "vor %lld Tagen",
        "it": "%lld giorni fa",
        "pl": "%lld dni temu",
        "ru": "%lld дн. назад",
        "sq": "%lld ditë më parë",
        "zh-Hans": "%lld 天前",
        "nl": "%lld dagen geleden",
    },
    "action_center_label_player": {
        "en": "Player",
        "es": "Jugador",
        "fr": "Joueur",
        "pt": "Jogador",
        "de": "Spieler",
        "it": "Giocatore",
        "pl": "Zawodnik",
        "ru": "Игрок",
        "sq": "Lojtar",
        "zh-Hans": "球员",
        "nl": "Speler",
    },
    "action_center_label_when": {
        "en": "When",
        "es": "Cuándo",
        "fr": "Quand",
        "pt": "Quando",
        "de": "Wann",
        "it": "Quando",
        "pl": "Kiedy",
        "ru": "Когда",
        "sq": "Kur",
        "zh-Hans": "时间",
        "nl": "Wanneer",
    },
    "action_center_label_where": {
        "en": "Where",
        "es": "Dónde",
        "fr": "Où",
        "pt": "Onde",
        "de": "Wo",
        "it": "Dove",
        "pl": "Gdzie",
        "ru": "Где",
        "sq": "Ku",
        "zh-Hans": "地点",
        "nl": "Waar",
    },
    "action_center_inbox_unread_count_a11y_format": {
        "en": "%lld unread",
        "es": "%lld no leídas",
        "fr": "%lld non lues",
        "pt": "%lld não lidas",
        "de": "%lld ungelesen",
        "it": "%lld non lette",
        "pl": "%lld nieprzeczytane",
        "ru": "%lld непрочитанных",
        "sq": "%lld të palexuara",
        "zh-Hans": "%lld 条未读",
        "nl": "%lld ongelezen",
    },
}


def main() -> None:
    data = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    strings = data.setdefault("strings", {})
    inserted = 0
    for key, translations in ENTRIES.items():
        if key not in strings:
            inserted += 1
        strings[key] = {
            "extractionState": "manual",
            "localizations": locs(translations),
        }

    minute = strings.get("going_pro_live_minute_a11y_format")
    if minute is not None:
        locs_map = minute.setdefault("localizations", {})
        for lang, value in MINUTE_VALUES.items():
            locs_map[lang] = unit(value)
            if "%" in value:
                raise SystemExit(f"minute key must not contain %: {lang}={value!r}")

    XCSTRINGS.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    en_minute = (
        strings.get("going_pro_live_minute_a11y_format", {})
        .get("localizations", {})
        .get("en", {})
        .get("stringUnit", {})
        .get("value")
    )
    if en_minute != "minute" or "%" in (en_minute or ""):
        raise SystemExit(f"minute key protection failed: {en_minute!r}")
    print(f"upserted {len(ENTRIES)} inbox redesign keys (inserted={inserted}); minute protected={en_minute!r}")


if __name__ == "__main__":
    main()
