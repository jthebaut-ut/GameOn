#!/usr/bin/env python3
"""Localization for richer Team event Inbox identity/change rows."""
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
    "action_center_label_team": {
        "en": "Team:",
        "es": "Equipo:",
        "fr": "Équipe :",
        "pt": "Equipe:",
        "de": "Team:",
        "it": "Squadra:",
        "pl": "Drużyna:",
        "ru": "Команда:",
        "sq": "Ekipi:",
        "zh-Hans": "球队：",
        "nl": "Team:",
    },
    "action_center_label_game": {
        "en": "Game:",
        "es": "Partido:",
        "fr": "Match :",
        "pt": "Jogo:",
        "de": "Spiel:",
        "it": "Partita:",
        "pl": "Mecz:",
        "ru": "Игра:",
        "sq": "Ndeshja:",
        "zh-Hans": "赛事：",
        "nl": "Wedstrijd:",
    },
    "action_center_label_date": {
        "en": "Date:",
        "es": "Fecha:",
        "fr": "Date :",
        "pt": "Data:",
        "de": "Datum:",
        "it": "Data:",
        "pl": "Data:",
        "ru": "Дата:",
        "sq": "Data:",
        "zh-Hans": "日期：",
        "nl": "Datum:",
    },
    "action_center_label_time": {
        "en": "Time:",
        "es": "Hora:",
        "fr": "Heure :",
        "pt": "Horário:",
        "de": "Uhrzeit:",
        "it": "Ora:",
        "pl": "Godzina:",
        "ru": "Время:",
        "sq": "Ora:",
        "zh-Hans": "时间：",
        "nl": "Tijd:",
    },
    "action_center_label_location": {
        "en": "Location:",
        "es": "Ubicación:",
        "fr": "Lieu :",
        "pt": "Local:",
        "de": "Ort:",
        "it": "Luogo:",
        "pl": "Miejsce:",
        "ru": "Место:",
        "sq": "Vendndodhja:",
        "zh-Hans": "地点：",
        "nl": "Locatie:",
    },
    "action_center_label_opponent": {
        "en": "Opponent:",
        "es": "Rival:",
        "fr": "Adversaire :",
        "pt": "Adversário:",
        "de": "Gegner:",
        "it": "Avversario:",
        "pl": "Rywal:",
        "ru": "Соперник:",
        "sq": "Kundërshtari:",
        "zh-Hans": "对手：",
        "nl": "Tegenstander:",
    },
    "action_center_label_status": {
        "en": "Status:",
        "es": "Estado:",
        "fr": "Statut :",
        "pt": "Status:",
        "de": "Status:",
        "it": "Stato:",
        "pl": "Status:",
        "ru": "Статус:",
        "sq": "Statusi:",
        "zh-Hans": "状态：",
        "nl": "Status:",
    },
    "action_center_label_announcement": {
        "en": "Announcement:",
        "es": "Anuncio:",
        "fr": "Annonce :",
        "pt": "Anúncio:",
        "de": "Ankündigung:",
        "it": "Annuncio:",
        "pl": "Ogłoszenie:",
        "ru": "Объявление:",
        "sq": "Njoftimi:",
        "zh-Hans": "公告：",
        "nl": "Mededeling:",
    },
    "action_center_status_cancelled": {
        "en": "Cancelled",
        "es": "Cancelado",
        "fr": "Annulé",
        "pt": "Cancelado",
        "de": "Abgesagt",
        "it": "Annullato",
        "pl": "Odwołane",
        "ru": "Отменено",
        "sq": "Anuluar",
        "zh-Hans": "已取消",
        "nl": "Geannuleerd",
    },
    "action_center_team_event_identity_format": {
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
    "action_center_team_event_a11y_labeled_format": {
        "en": "%@ %@",
        "es": "%@ %@",
        "fr": "%@ %@",
        "pt": "%@ %@",
        "de": "%@ %@",
        "it": "%@ %@",
        "pl": "%@ %@",
        "ru": "%@ %@",
        "sq": "%@ %@",
        "zh-Hans": "%@ %@",
        "nl": "%@ %@",
    },
    "action_center_team_event_a11y_changed_format": {
        "en": "%@ changed from %@ to %@",
        "es": "%@ cambió de %@ a %@",
        "fr": "%@ est passé de %@ à %@",
        "pt": "%@ mudou de %@ para %@",
        "de": "%@ geändert von %@ zu %@",
        "it": "%@ cambiato da %@ a %@",
        "pl": "%@: zmieniono z %@ na %@",
        "ru": "%@: изменено с %@ на %@",
        "sq": "%@ ndryshoi nga %@ në %@",
        "zh-Hans": "%@已从%@改为%@",
        "nl": "%@ gewijzigd van %@ naar %@",
    },
    "action_center_team_notif_time_changed_format": {
        "en": "%@ time changed",
        "es": "Hora de %@ cambiada",
        "fr": "Horaire de %@ modifié",
        "pt": "Horário de %@ alterado",
        "de": "%@-Uhrzeit geändert",
        "it": "Orario di %@ modificato",
        "pl": "Zmieniono godzinę: %@",
        "ru": "Изменено время: %@",
        "sq": "Ora e %@ u ndryshua",
        "zh-Hans": "%@时间已更改",
        "nl": "%@-tijd gewijzigd",
    },
    "action_center_team_notif_date_changed_format": {
        "en": "%@ date changed",
        "es": "Fecha de %@ cambiada",
        "fr": "Date de %@ modifiée",
        "pt": "Data de %@ alterada",
        "de": "%@-Datum geändert",
        "it": "Data di %@ modificata",
        "pl": "Zmieniono datę: %@",
        "ru": "Изменена дата: %@",
        "sq": "Data e %@ u ndryshua",
        "zh-Hans": "%@日期已更改",
        "nl": "%@-datum gewijzigd",
    },
    "action_center_team_notif_location_changed_format": {
        "en": "%@ location changed",
        "es": "Ubicación de %@ cambiada",
        "fr": "Lieu de %@ modifié",
        "pt": "Local de %@ alterado",
        "de": "%@-Ort geändert",
        "it": "Luogo di %@ modificato",
        "pl": "Zmieniono miejsce: %@",
        "ru": "Изменено место: %@",
        "sq": "Vendndodhja e %@ u ndryshua",
        "zh-Hans": "%@地点已更改",
        "nl": "%@-locatie gewijzigd",
    },
    "action_center_team_notif_opponent_changed_format": {
        "en": "%@ opponent changed",
        "es": "Rival de %@ cambiado",
        "fr": "Adversaire de %@ modifié",
        "pt": "Adversário de %@ alterado",
        "de": "%@-Gegner geändert",
        "it": "Avversario di %@ modificato",
        "pl": "Zmieniono rywala: %@",
        "ru": "Изменён соперник: %@",
        "sq": "Kundërshtari i %@ u ndryshua",
        "zh-Hans": "%@对手已更改",
        "nl": "%@-tegenstander gewijzigd",
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
    print(f"patched {len(ENTRIES)} keys")


if __name__ == "__main__":
    main()
