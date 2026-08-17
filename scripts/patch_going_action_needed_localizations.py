#!/usr/bin/env python3
"""Localization for Going Action Needed + Going tab badge."""
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
    "going_action_needed_count_format": {
        "en": "Action Needed (%lld)",
        "es": "Acción necesaria (%lld)",
        "fr": "Action requise (%lld)",
        "pt": "Ação necessária (%lld)",
        "de": "Aktion erforderlich (%lld)",
        "it": "Azione richiesta (%lld)",
        "pl": "Wymagane działanie (%lld)",
        "ru": "Требуется действие (%lld)",
        "sq": "Kërkohet veprim (%lld)",
        "zh-Hans": "需要处理（%lld）",
    },
    "going_action_needed_invite_format": {
        "en": "Pickup game invitation awaiting response · %@",
        "es": "Invitación a un partido pickup pendiente · %@",
        "fr": "Invitation pickup en attente de réponse · %@",
        "pt": "Convite de partida pickup aguardando resposta · %@",
        "de": "Pickup-Einladung wartet auf Antwort · %@",
        "it": "Invito pickup in attesa di risposta · %@",
        "pl": "Zaproszenie pickup czeka na odpowiedź · %@",
        "ru": "Приглашение на пикап ждёт ответа · %@",
        "sq": "Ftesa pickup pret përgjigje · %@",
        "zh-Hans": "待回复的约球邀请 · %@",
    },
    "going_action_needed_rsvp_tomorrow_format": {
        "en": "RSVP required for tomorrow's %@",
        "es": "Confirma asistencia para %@ de mañana",
        "fr": "Réponse requise pour %@ de demain",
        "pt": "Confirme presença para %@ de amanhã",
        "de": "Zusage nötig für morgiges %@",
        "it": "Conferma richiesta per %@ di domani",
        "pl": "Potwierdź obecność na jutrzejsze %@",
        "ru": "Нужен ответ на завтрашнее %@",
        "sq": "Kërkohet konfirmim për %@ e nesërme",
        "zh-Hans": "请回复明天的%@",
    },
    "going_action_needed_rsvp_format": {
        "en": "RSVP required for %@",
        "es": "Confirma asistencia para %@",
        "fr": "Réponse requise pour %@",
        "pt": "Confirme presença para %@",
        "de": "Zusage nötig für %@",
        "it": "Conferma richiesta per %@",
        "pl": "Potwierdź obecność na %@",
        "ru": "Нужен ответ на %@",
        "sq": "Kërkohet konfirmim për %@",
        "zh-Hans": "请回复%@",
    },
    "going_action_needed_join_format": {
        "en": "%@ wants to join %@",
        "es": "%@ quiere unirse a %@",
        "fr": "%@ veut rejoindre %@",
        "pt": "%@ quer entrar em %@",
        "de": "%@ möchte %@ beitreten",
        "it": "%@ vuole unirsi a %@",
        "pl": "%@ chce dołączyć do %@",
        "ru": "%@ хочет присоединиться к %@",
        "sq": "%@ dëshiron t’i bashkohet %@",
        "zh-Hans": "%@ 想加入 %@",
    },
    "going_action_needed_confirmation_needed": {
        "en": "Your event needs confirmation",
        "es": "Tu evento necesita confirmación",
        "fr": "Votre événement nécessite une confirmation",
        "pt": "Seu evento precisa de confirmação",
        "de": "Dein Event braucht eine Bestätigung",
        "it": "Il tuo evento richiede una conferma",
        "pl": "Twoje wydarzenie wymaga potwierdzenia",
        "ru": "Ваше событие требует подтверждения",
        "sq": "Ngjarja jote kërkon konfirmim",
        "zh-Hans": "你的活动需要确认",
    },
    "going_action_needed_time_changed_format": {
        "en": "Game time changed for %@",
        "es": "Cambió el horario de %@",
        "fr": "Horaire modifié pour %@",
        "pt": "Horário alterado para %@",
        "de": "Spielzeit geändert für %@",
        "it": "Orario cambiato per %@",
        "pl": "Zmieniono godzinę dla %@",
        "ru": "Изменено время для %@",
        "sq": "Ora e ndeshjes ndryshoi për %@",
        "zh-Hans": "%@ 的时间已更改",
    },
    "going_action_needed_location_changed_format": {
        "en": "Event location changed for %@",
        "es": "Cambió la ubicación de %@",
        "fr": "Lieu modifié pour %@",
        "pt": "Local alterado para %@",
        "de": "Ort geändert für %@",
        "it": "Luogo cambiato per %@",
        "pl": "Zmieniono miejsce dla %@",
        "ru": "Изменено место для %@",
        "sq": "Vendndodhja ndryshoi për %@",
        "zh-Hans": "%@ 的地点已更改",
    },
    "going_action_needed_schedule_changed_format": {
        "en": "Schedule updated for %@",
        "es": "Horario actualizado para %@",
        "fr": "Planning mis à jour pour %@",
        "pt": "Agenda atualizada para %@",
        "de": "Zeitplan aktualisiert für %@",
        "it": "Programma aggiornato per %@",
        "pl": "Zaktualizowano harmonogram dla %@",
        "ru": "Расписание обновлено для %@",
        "sq": "Orari u përditësua për %@",
        "zh-Hans": "%@ 的日程已更新",
    },
    "going_action_needed_cancelled_format": {
        "en": "%@ was cancelled",
        "es": "%@ fue cancelado",
        "fr": "%@ a été annulé",
        "pt": "%@ foi cancelado",
        "de": "%@ wurde abgesagt",
        "it": "%@ è stato annullato",
        "pl": "Odwołano %@",
        "ru": "%@ отменено",
        "sq": "%@ u anulua",
        "zh-Hans": "%@ 已取消",
    },
    "going_action_needed_starts_soon_hour_format": {
        "en": "%@ starts in 1 hour",
        "es": "%@ empieza en 1 hora",
        "fr": "%@ commence dans 1 heure",
        "pt": "%@ começa em 1 hora",
        "de": "%@ beginnt in 1 Stunde",
        "it": "%@ inizia tra 1 ora",
        "pl": "%@ zaczyna się za 1 godzinę",
        "ru": "%@ начнётся через 1 час",
        "sq": "%@ fillon pas 1 ore",
        "zh-Hans": "%@ 将在 1 小时后开始",
    },
    "going_action_needed_starts_soon_minutes_format": {
        "en": "%@ starts in %@ minutes",
        "es": "%@ empieza en %@ minutos",
        "fr": "%@ commence dans %@ minutes",
        "pt": "%@ começa em %@ minutos",
        "de": "%@ beginnt in %@ Minuten",
        "it": "%@ inizia tra %@ minuti",
        "pl": "%@ zaczyna się za %@ min",
        "ru": "%@ начнётся через %@ мин.",
        "sq": "%@ fillon pas %@ minutash",
        "zh-Hans": "%@ 将在 %@ 分钟后开始",
    },
    "going_action_needed_rating_format": {
        "en": "Rate your organizer for %@",
        "es": "Valora al organizador de %@",
        "fr": "Notez l’organisateur de %@",
        "pt": "Avalie o organizador de %@",
        "de": "Bewerte den Organisator von %@",
        "it": "Valuta l’organizzatore di %@",
        "pl": "Oceń organizatora: %@",
        "ru": "Оцените организатора: %@",
        "sq": "Vlerëso organizatorin për %@",
        "zh-Hans": "为%@评价组织者",
    },
    "going_action_needed_announcement_format": {
        "en": "Team announcement not yet read · %@",
        "es": "Anuncio del equipo sin leer · %@",
        "fr": "Annonce d’équipe non lue · %@",
        "pt": "Anúncio da equipe não lido · %@",
        "de": "Team-Ankündigung ungelesen · %@",
        "it": "Annuncio della squadra non letto · %@",
        "pl": "Nieprzeczytane ogłoszenie drużyny · %@",
        "ru": "Непрочитанное объявление команды · %@",
        "sq": "Njoftim ekipi i palexuar · %@",
        "zh-Hans": "未读的球队公告 · %@",
    },
    "going_action_needed_badge_a11y": {
        "en": "%lld Action Needed",
        "es": "%lld Acción necesaria",
        "fr": "%lld Action requise",
        "pt": "%lld Ação necessária",
        "de": "%lld Aktion erforderlich",
        "it": "%lld Azione richiesta",
        "pl": "%lld wymagane działania",
        "ru": "%lld требуют действия",
        "sq": "%lld kërkojnë veprim",
        "zh-Hans": "%lld 项需要处理",
    },
    "going_action_needed_row_a11y_hint": {
        "en": "Opens the related Going screen",
        "es": "Abre la pantalla de Going relacionada",
        "fr": "Ouvre l’écran Going correspondant",
        "pt": "Abre a tela Going relacionada",
        "de": "Öffnet die passende Going-Ansicht",
        "it": "Apre la schermata Going correlata",
        "pl": "Otwiera powiązany ekran Going",
        "ru": "Открывает связанный экран Going",
        "sq": "Hap ekranin Going përkatës",
        "zh-Hans": "打开相关的 Going 页面",
    },
}


def main() -> None:
    data = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    strings = data.setdefault("strings", {})
    for key, translations in ENTRIES.items():
        en = translations["en"]
        entry = strings.get(key, {})
        entry["extractionState"] = "manual"
        entry["localizations"] = locs(en, {k: v for k, v in translations.items() if k != "en"})
        strings[key] = entry
    XCSTRINGS.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Patched {len(ENTRIES)} keys into {XCSTRINGS}")


if __name__ == "__main__":
    main()
