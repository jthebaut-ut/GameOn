#!/usr/bin/env python3
"""Join request Action Center + review + capacity + decision notification strings."""
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
    "pickup_join_capacity_players_format": {
        "en": "%lld / %lld players",
        "es": "%lld / %lld jugadores",
        "fr": "%lld / %lld joueurs",
        "pt": "%lld / %lld jogadores",
        "de": "%lld / %lld Spieler",
        "it": "%lld / %lld giocatori",
        "pl": "%lld / %lld zawodników",
        "ru": "%lld / %lld игроков",
        "sq": "%lld / %lld lojtarë",
        "zh-Hans": "%lld / %lld 名球员",
    },
    "pickup_join_capacity_full_format": {
        "en": "%lld / %lld Full",
        "es": "%lld / %lld Completo",
        "fr": "%lld / %lld Complet",
        "pt": "%lld / %lld Lotado",
        "de": "%lld / %lld Voll",
        "it": "%lld / %lld Completo",
        "pl": "%lld / %lld Pełny",
        "ru": "%lld / %lld Полный",
        "sq": "%lld / %lld Plot",
        "zh-Hans": "%lld / %lld 已满",
    },
    "pickup_join_review_event_section": {
        "en": "Event",
        "es": "Evento",
        "fr": "Événement",
        "pt": "Evento",
        "de": "Event",
        "it": "Evento",
        "pl": "Wydarzenie",
        "ru": "Событие",
        "sq": "Ngjarja",
        "zh-Hans": "活动",
    },
    "pickup_join_review_date_section": {
        "en": "Date",
        "es": "Fecha",
        "fr": "Date",
        "pt": "Data",
        "de": "Datum",
        "it": "Data",
        "pl": "Data",
        "ru": "Дата",
        "sq": "Data",
        "zh-Hans": "日期",
    },
    "pickup_join_review_location_section": {
        "en": "Location",
        "es": "Ubicación",
        "fr": "Lieu",
        "pt": "Local",
        "de": "Ort",
        "it": "Luogo",
        "pl": "Lokalizacja",
        "ru": "Место",
        "sq": "Vendndodhja",
        "zh-Hans": "地点",
    },
    "pickup_join_review_capacity_section": {
        "en": "Capacity",
        "es": "Capacidad",
        "fr": "Capacité",
        "pt": "Capacidade",
        "de": "Kapazität",
        "it": "Capienza",
        "pl": "Pojemność",
        "ru": "Вместимость",
        "sq": "Kapaciteti",
        "zh-Hans": "名额",
    },
    "pickup_join_full_confirm_title": {
        "en": "This event is already full.",
        "es": "Este evento ya está completo.",
        "fr": "Cet événement est déjà complet.",
        "pt": "Este evento já está lotado.",
        "de": "Dieses Event ist bereits voll.",
        "it": "Questo evento è già al completo.",
        "pl": "To wydarzenie jest już pełne.",
        "ru": "Это событие уже заполнено.",
        "sq": "Kjo ngjarje është tashmë e plotë.",
        "zh-Hans": "此活动已满员。",
    },
    "pickup_join_full_confirm_message": {
        "en": "Approving this request will increase attendance beyond the preferred capacity.\n\nContinue?",
        "es": "Aprobar esta solicitud aumentará la asistencia por encima de la capacidad preferida.\n\n¿Continuar?",
        "fr": "Approuver cette demande fera dépasser la capacité préférée.\n\nContinuer ?",
        "pt": "Aprovar este pedido aumentará a presença além da capacidade preferida.\n\nContinuar?",
        "de": "Wenn du diese Anfrage genehmigst, wird die bevorzugte Kapazität überschritten.\n\nFortfahren?",
        "it": "L’approvazione di questa richiesta supererà la capienza preferita.\n\nContinuare?",
        "pl": "Zatwierdzenie tej prośby zwiększy frekwencję ponad preferowaną pojemność.\n\nKontynuować?",
        "ru": "Одобрение этой заявки увеличит число участников сверх предпочтительной вместимости.\n\nПродолжить?",
        "sq": "Miratimi i kësaj kërkese do ta rrisë pjesëmarrjen përtej kapacitetit të preferuar.\n\nTë vazhdohet?",
        "zh-Hans": "批准此请求将使人数超过首选名额。\n\n继续？",
    },
    "action_center_join_decision_title": {
        "en": "Your request to join",
        "es": "Tu solicitud para unirte",
        "fr": "Votre demande pour rejoindre",
        "pt": "Seu pedido para participar",
        "de": "Deine Beitrittsanfrage",
        "it": "La tua richiesta di unirti",
        "pl": "Twoja prośba o dołączenie",
        "ru": "Ваша заявка на участие",
        "sq": "Kërkesa jote për t’u bashkuar",
        "zh-Hans": "你的加入申请",
    },
    "action_center_join_decision_approved_format": {
        "en": "%@ was approved.",
        "es": "%@ fue aprobada.",
        "fr": "%@ a été approuvée.",
        "pt": "%@ foi aprovado.",
        "de": "%@ wurde genehmigt.",
        "it": "%@ è stata approvata.",
        "pl": "%@ została zatwierdzona.",
        "ru": "%@ одобрена.",
        "sq": "%@ u miratua.",
        "zh-Hans": "%@ 已获批准。",
    },
    "action_center_join_decision_declined_format": {
        "en": "%@ was declined.",
        "es": "%@ fue rechazada.",
        "fr": "%@ a été refusée.",
        "pt": "%@ foi recusado.",
        "de": "%@ wurde abgelehnt.",
        "it": "%@ è stata rifiutata.",
        "pl": "%@ została odrzucona.",
        "ru": "%@ отклонена.",
        "sq": "%@ u refuzua.",
        "zh-Hans": "%@ 已被拒绝。",
    },
}


def main() -> None:
    data = json.loads(XCSTRINGS.read_text())
    strings = data.setdefault("strings", {})
    added = 0
    for key, translations in ENTRIES.items():
        entry = strings.setdefault(key, {})
        loc = entry.setdefault("localizations", {})
        for lang, unit_value in locs(translations["en"], translations).items():
            if lang not in loc:
                loc[lang] = unit_value
                added += 1
    XCSTRINGS.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    print(f"patched {len(ENTRIES)} keys, {added} new localizations")


if __name__ == "__main__":
    main()
