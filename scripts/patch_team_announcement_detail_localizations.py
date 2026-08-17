#!/usr/bin/env python3
"""Localization for Team Announcement detail screen redesign."""
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
    "team_announcement_detail_nav_title": {
        "en": "Team Announcement",
        "es": "Anuncio del equipo",
        "fr": "Annonce d’équipe",
        "pt": "Anúncio da equipe",
        "de": "Team-Ankündigung",
        "it": "Annuncio della squadra",
        "pl": "Ogłoszenie drużyny",
        "ru": "Объявление команды",
        "sq": "Njoftim i ekipit",
        "zh-Hans": "队伍公告",
    },
    "team_announcement_detail_hero_title": {
        "en": "Team Announcement",
        "es": "Anuncio del equipo",
        "fr": "Annonce d’équipe",
        "pt": "Anúncio da equipe",
        "de": "Team-Ankündigung",
        "it": "Annuncio della squadra",
        "pl": "Ogłoszenie drużyny",
        "ru": "Объявление команды",
        "sq": "Njoftim i ekipit",
        "zh-Hans": "队伍公告",
    },
    "team_announcement_detail_message_section": {
        "en": "Announcement",
        "es": "Anuncio",
        "fr": "Annonce",
        "pt": "Anúncio",
        "de": "Ankündigung",
        "it": "Annuncio",
        "pl": "Ogłoszenie",
        "ru": "Объявление",
        "sq": "Njoftim",
        "zh-Hans": "公告",
    },
    "team_announcement_detail_from_name_format": {
        "en": "From %@",
        "es": "De %@",
        "fr": "De %@",
        "pt": "De %@",
        "de": "Von %@",
        "it": "Da %@",
        "pl": "Od %@",
        "ru": "От %@",
        "sq": "Nga %@",
        "zh-Hans": "来自 %@",
    },
    "team_announcement_detail_from_name_role_format": {
        "en": "From %@ (%@)",
        "es": "De %@ (%@)",
        "fr": "De %@ (%@)",
        "pt": "De %@ (%@)",
        "de": "Von %@ (%@)",
        "it": "Da %@ (%@)",
        "pl": "Od %@ (%@)",
        "ru": "От %@ (%@)",
        "sq": "Nga %@ (%@)",
        "zh-Hans": "来自 %@（%@）",
    },
    "team_announcement_detail_sent_to_entire_team": {
        "en": "Sent to Entire Team",
        "es": "Enviado a todo el equipo",
        "fr": "Envoyé à toute l’équipe",
        "pt": "Enviado a toda a equipe",
        "de": "An das gesamte Team gesendet",
        "it": "Inviato a tutta la squadra",
        "pl": "Wysłano do całej drużyny",
        "ru": "Отправлено всей команде",
        "sq": "Dërguar te i gjithë ekipi",
        "zh-Hans": "已发送给全体队员",
    },
    "team_announcement_detail_sent_to_count_format": {
        "en": "Sent to %lld Team Members",
        "es": "Enviado a %lld miembros del equipo",
        "fr": "Envoyé à %lld membres de l’équipe",
        "pt": "Enviado a %lld membros da equipe",
        "de": "An %lld Teammitglieder gesendet",
        "it": "Inviato a %lld membri della squadra",
        "pl": "Wysłano do %lld członków drużyny",
        "ru": "Отправлено %lld участникам команды",
        "sq": "Dërguar te %lld anëtarë të ekipit",
        "zh-Hans": "已发送给 %lld 名队员",
    },
}


def main() -> None:
    data = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    strings = data.setdefault("strings", {})
    for key, translations in ENTRIES.items():
        entry = strings.get(key) or {"extractionState": "manual", "localizations": {}}
        entry["extractionState"] = "manual"
        locs_map = entry.setdefault("localizations", {})
        for lang, payload in locs(translations).items():
            locs_map[lang] = payload
        strings[key] = entry
    XCSTRINGS.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Patched {len(ENTRIES)} keys into {XCSTRINGS}")


if __name__ == "__main__":
    main()
