#!/usr/bin/env python3
"""Localization for Team Event Detail visual redesign."""
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
    "team_event_detail_nav_title": {
        "en": "Event Details",
        "es": "Detalles del evento",
        "fr": "Détails de l’événement",
        "pt": "Detalhes do evento",
        "de": "Eventdetails",
        "it": "Dettagli evento",
        "nl": "Evenementdetails",
        "pl": "Szczegóły wydarzenia",
        "ru": "Детали события",
        "sq": "Detajet e eventit",
        "zh-Hans": "活动详情",
    },
    "team_event_youre_going": {
        "en": "You’re going!",
        "es": "¡Vas a ir!",
        "fr": "Vous y allez !",
        "pt": "Você vai!",
        "de": "Du gehst hin!",
        "it": "Ci sei!",
        "nl": "Je gaat!",
        "pl": "Idziesz!",
        "ru": "Вы идёте!",
        "sq": "Po shkon!",
        "zh-Hans": "你要去！",
    },
    "team_event_youre_maybe": {
        "en": "Maybe",
        "es": "Tal vez",
        "fr": "Peut-être",
        "pt": "Talvez",
        "de": "Vielleicht",
        "it": "Forse",
        "nl": "Misschien",
        "pl": "Może",
        "ru": "Возможно",
        "sq": "Ndoshta",
        "zh-Hans": "待定",
    },
    "team_event_you_cant_go": {
        "en": "Can’t go",
        "es": "No puedes ir",
        "fr": "Indisponible",
        "pt": "Não pode ir",
        "de": "Kann nicht",
        "it": "Non puoi",
        "nl": "Kan niet",
        "pl": "Nie możesz",
        "ru": "Не можете",
        "sq": "Nuk mund",
        "zh-Hans": "无法参加",
    },
    "team_event_more_details_subtitle": {
        "en": "Notes, reminders, and more",
        "es": "Notas, recordatorios y más",
        "fr": "Notes, rappels et plus",
        "pt": "Notas, lembretes e mais",
        "de": "Notizen, Erinnerungen und mehr",
        "it": "Note, promemoria e altro",
        "nl": "Notities, herinneringen en meer",
        "pl": "Notatki, przypomnienia i więcej",
        "ru": "Заметки, напоминания и ещё",
        "sq": "Shënime, kujtesa dhe më shumë",
        "zh-Hans": "备注、提醒等",
    },
    "team_event_status_started": {
        "en": "Started",
        "es": "En curso",
        "fr": "Commencé",
        "pt": "Iniciado",
        "de": "Gestartet",
        "it": "Iniziato",
        "nl": "Gestart",
        "pl": "Rozpoczęte",
        "ru": "Началось",
        "sq": "Filluar",
        "zh-Hans": "已开始",
    },
    "team_event_whos_going_empty": {
        "en": "No responses yet",
        "es": "Aún no hay respuestas",
        "fr": "Pas encore de réponses",
        "pt": "Ainda sem respostas",
        "de": "Noch keine Antworten",
        "it": "Ancora nessuna risposta",
        "nl": "Nog geen reacties",
        "pl": "Brak odpowiedzi",
        "ru": "Пока нет ответов",
        "sq": "Ende pa përgjigje",
        "zh-Hans": "暂无回复",
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
