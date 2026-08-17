#!/usr/bin/env python3
"""Localization for polished Team Action Center notification copy."""
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
    "action_center_team_notif_created_format": {
        "en": "%@ created",
        "es": "%@ creado",
        "fr": "%@ créé",
        "pt": "%@ criado",
        "de": "%@ erstellt",
        "it": "%@ creato",
        "pl": "Utworzono: %@",
        "ru": "%@ создано",
        "sq": "%@ u krijua",
        "zh-Hans": "已创建%@",
        "nl": "%@ aangemaakt",
    },
    "action_center_team_notif_time_changed_format": {
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
    "action_center_team_notif_moved_format": {
        "en": "%@ moved",
        "es": "%@ trasladado",
        "fr": "%@ déplacé",
        "pt": "%@ transferido",
        "de": "%@ verlegt",
        "it": "%@ spostato",
        "pl": "Przeniesiono: %@",
        "ru": "%@ перенесено",
        "sq": "%@ u zhvendos",
        "zh-Hans": "%@已改地点",
        "nl": "%@ verplaatst",
    },
    "action_center_team_notif_rescheduled_format": {
        "en": "%@ rescheduled",
        "es": "%@ reprogramado",
        "fr": "%@ reprogrammé",
        "pt": "%@ reagendado",
        "de": "%@ neu angesetzt",
        "it": "%@ riprogrammato",
        "pl": "Przełożono: %@",
        "ru": "%@ перенесено",
        "sq": "%@ u riprogramua",
        "zh-Hans": "%@已改期",
        "nl": "%@ verzet",
    },
    "action_center_team_notif_cancelled_format": {
        "en": "%@ cancelled",
        "es": "%@ cancelado",
        "fr": "%@ annulé",
        "pt": "%@ cancelado",
        "de": "%@ abgesagt",
        "it": "%@ annullato",
        "pl": "Odwołano: %@",
        "ru": "%@ отменено",
        "sq": "%@ u anulua",
        "zh-Hans": "%@已取消",
        "nl": "%@ geannuleerd",
    },
    "action_center_team_notif_updated_format": {
        "en": "%@ updated",
        "es": "%@ actualizado",
        "fr": "%@ mis à jour",
        "pt": "%@ atualizado",
        "de": "%@ aktualisiert",
        "it": "%@ aggiornato",
        "pl": "Zaktualizowano: %@",
        "ru": "%@ обновлено",
        "sq": "%@ u përditësua",
        "zh-Hans": "%@已更新",
        "nl": "%@ bijgewerkt",
    },
    "action_center_team_notif_announcement": {
        "en": "Team Announcement",
        "es": "Anuncio del equipo",
        "fr": "Annonce d’équipe",
        "pt": "Anúncio da equipe",
        "de": "Team-Ankündigung",
        "it": "Annuncio del team",
        "pl": "Ogłoszenie drużyny",
        "ru": "Объявление команды",
        "sq": "Njoftim i ekipit",
        "zh-Hans": "球队公告",
        "nl": "Teammededeling",
    },
    "action_center_team_header_format": {
        "en": "%@ · %@",
        "es": "%@ · %@",
        "fr": "%@ · %@",
        "pt": "%@ · %@",
        "de": "%@ · %@",
        "it": "%@ · %@",
        "pl": "%@ · %@",
        "ru": "%@ · %@",
        "sq": "%@ · %@",
        "zh-Hans": "%@ · %@",
        "nl": "%@ · %@",
    },
    "action_center_team_notif_event_noun": {
        "en": "Event",
        "es": "Evento",
        "fr": "Événement",
        "pt": "Evento",
        "de": "Termin",
        "it": "Evento",
        "pl": "Wydarzenie",
        "ru": "Событие",
        "sq": "Ngjarje",
        "zh-Hans": "活动",
        "nl": "Evenement",
    },
    "action_center_team_notif_quote_format": {
        "en": "“%@”",
        "es": "«%@»",
        "fr": "« %@ »",
        "pt": "“%@”",
        "de": "„%@“",
        "it": "«%@»",
        "pl": "„%@”",
        "ru": "«%@»",
        "sq": "“%@”",
        "zh-Hans": "「%@」",
        "nl": "“%@”",
    },
    "action_center_team_notif_when_format": {
        "en": "%@ • %@",
        "es": "%@ • %@",
        "fr": "%@ • %@",
        "pt": "%@ • %@",
        "de": "%@ • %@",
        "it": "%@ • %@",
        "pl": "%@ • %@",
        "ru": "%@ • %@",
        "sq": "%@ • %@",
        "zh-Hans": "%@ • %@",
        "nl": "%@ • %@",
    },
    "action_center_badge_team_update": {
        "en": "TEAM",
        "es": "EQUIPO",
        "fr": "ÉQUIPE",
        "pt": "EQUIPE",
        "de": "TEAM",
        "it": "TEAM",
        "pl": "DRUŻYNA",
        "ru": "КОМАНДА",
        "sq": "EKIP",
        "zh-Hans": "球队",
        "nl": "TEAM",
    },
    "action_center_badge_new_event": {
        "en": "NEW",
        "es": "NUEVO",
        "fr": "NOUVEAU",
        "pt": "NOVO",
        "de": "NEU",
        "it": "NUOVO",
        "pl": "NOWE",
        "ru": "НОВОЕ",
        "sq": "E RE",
        "zh-Hans": "新建",
        "nl": "NIEUW",
    },
    "action_center_badge_announcement": {
        "en": "ANNOUNCEMENT",
        "es": "ANUNCIO",
        "fr": "ANNONCE",
        "pt": "ANÚNCIO",
        "de": "ANKÜNDIGUNG",
        "it": "ANNUNCIO",
        "pl": "OGŁOSZENIE",
        "ru": "ОБЪЯВЛЕНИЕ",
        "sq": "NJOFTIM",
        "zh-Hans": "公告",
        "nl": "MEDEDELING",
    },
}


def main() -> None:
    data = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    strings = data.setdefault("strings", {})
    for key, translations in ENTRIES.items():
        entry = strings.get(key) or {"extractionState": "manual", "localizations": {}}
        entry["extractionState"] = "manual"
        entry["localizations"] = locs(translations)
        strings[key] = entry
    XCSTRINGS.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"patched {len(ENTRIES)} Team notification Action Center keys")


if __name__ == "__main__":
    main()
