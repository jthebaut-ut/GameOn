#!/usr/bin/env python3
"""Add Action Center enrichment localization keys to Localizable.xcstrings."""
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


# English + lightweight translations for all FanGeo locales.
ENTRIES: dict[str, dict[str, str]] = {
    "action_center_wants_to_join_format": {
        "en": "%@ wants to join",
        "es": "%@ quiere unirse",
        "fr": "%@ souhaite rejoindre",
        "pt": "%@ quer participar",
        "de": "%@ möchte beitreten",
        "it": "%@ vuole unirsi",
        "pl": "%@ chce dołączyć",
        "ru": "%@ хочет присоединиться",
        "sq": "%@ dëshiron të bashkohet",
        "zh-Hans": "%@ 想加入",
    },
    "action_center_event_changed_format": {
        "en": "%@ changed",
        "es": "%@ cambió",
        "fr": "%@ a changé",
        "pt": "%@ mudou",
        "de": "%@ wurde geändert",
        "it": "%@ è cambiato",
        "pl": "%@ zostało zmienione",
        "ru": "%@ изменено",
        "sq": "%@ u ndryshua",
        "zh-Hans": "%@ 已更改",
    },
    "action_center_event_cancelled_format": {
        "en": "%@ cancelled",
        "es": "%@ cancelado",
        "fr": "%@ annulé",
        "pt": "%@ cancelado",
        "de": "%@ abgesagt",
        "it": "%@ annullato",
        "pl": "%@ odwołane",
        "ru": "%@ отменено",
        "sq": "%@ u anulua",
        "zh-Hans": "%@ 已取消",
    },
    "action_center_change_time": {
        "en": "Time changed",
        "es": "Hora cambiada",
        "fr": "Heure modifiée",
        "pt": "Horário alterado",
        "de": "Zeit geändert",
        "it": "Orario modificato",
        "pl": "Zmieniono godzinę",
        "ru": "Время изменено",
        "sq": "Ora u ndryshua",
        "zh-Hans": "时间已更改",
    },
    "action_center_change_end_time": {
        "en": "End time changed",
        "es": "Hora de fin cambiada",
        "fr": "Heure de fin modifiée",
        "pt": "Horário de término alterado",
        "de": "Endzeit geändert",
        "it": "Orario di fine modificato",
        "pl": "Zmieniono godzinę zakończenia",
        "ru": "Время окончания изменено",
        "sq": "Ora e mbarimit u ndryshua",
        "zh-Hans": "结束时间已更改",
    },
    "action_center_change_location": {
        "en": "Location changed",
        "es": "Ubicación cambiada",
        "fr": "Lieu modifié",
        "pt": "Local alterado",
        "de": "Ort geändert",
        "it": "Luogo modificato",
        "pl": "Zmieniono lokalizację",
        "ru": "Место изменено",
        "sq": "Vendndodhja u ndryshua",
        "zh-Hans": "地点已更改",
    },
    "action_center_change_cancelled": {
        "en": "Event cancelled",
        "es": "Evento cancelado",
        "fr": "Événement annulé",
        "pt": "Evento cancelado",
        "de": "Event abgesagt",
        "it": "Evento annullato",
        "pl": "Wydarzenie odwołane",
        "ru": "Событие отменено",
        "sq": "Ngjarja u anulua",
        "zh-Hans": "活动已取消",
    },
    "action_center_change_title": {
        "en": "Event name changed",
        "es": "Nombre del evento cambiado",
        "fr": "Nom de l’événement modifié",
        "pt": "Nome do evento alterado",
        "de": "Eventname geändert",
        "it": "Nome evento modificato",
        "pl": "Zmieniono nazwę wydarzenia",
        "ru": "Название события изменено",
        "sq": "Emri i ngjarjes u ndryshua",
        "zh-Hans": "活动名称已更改",
    },
    "action_center_change_event_type": {
        "en": "Event type changed",
        "es": "Tipo de evento cambiado",
        "fr": "Type d’événement modifié",
        "pt": "Tipo de evento alterado",
        "de": "Eventtyp geändert",
        "it": "Tipo evento modificato",
        "pl": "Zmieniono typ wydarzenia",
        "ru": "Тип события изменён",
        "sq": "Lloji i ngjarjes u ndryshua",
        "zh-Hans": "活动类型已更改",
    },
    "action_center_change_capacity": {
        "en": "Capacity changed",
        "es": "Capacidad cambiada",
        "fr": "Capacité modifiée",
        "pt": "Capacidade alterada",
        "de": "Kapazität geändert",
        "it": "Capienza modificata",
        "pl": "Zmieniono liczbę miejsc",
        "ru": "Вместимость изменена",
        "sq": "Kapaciteti u ndryshua",
        "zh-Hans": "人数上限已更改",
    },
    "action_center_value_arrow_format": {
        "en": "%@ → %@",
        "es": "%@ → %@",
        "fr": "%@ → %@",
        "pt": "%@ → %@",
        "de": "%@ → %@",
        "it": "%@ → %@",
        "pl": "%@ → %@",
        "ru": "%@ → %@",
        "sq": "%@ → %@",
        "zh-Hans": "%@ → %@",
    },
    "action_center_more_changes_format": {
        "en": "+%lld more changes",
        "es": "+%lld cambios más",
        "fr": "+%lld autres changements",
        "pt": "+%lld outras alterações",
        "de": "+%lld weitere Änderungen",
        "it": "+%lld altre modifiche",
        "pl": "+%lld kolejnych zmian",
        "ru": "Ещё +%lld изменений",
        "sq": "+%lld ndryshime të tjera",
        "zh-Hans": "另有 %lld 项更改",
    },
    "action_center_cta_view_game": {
        "en": "View Game",
        "es": "Ver partido",
        "fr": "Voir le match",
        "pt": "Ver jogo",
        "de": "Spiel ansehen",
        "it": "Vedi partita",
        "pl": "Zobacz grę",
        "ru": "Открыть игру",
        "sq": "Shiko lojën",
        "zh-Hans": "查看比赛",
    },
    "action_center_cta_view_event": {
        "en": "View Event",
        "es": "Ver evento",
        "fr": "Voir l’événement",
        "pt": "Ver evento",
        "de": "Event ansehen",
        "it": "Vedi evento",
        "pl": "Zobacz wydarzenie",
        "ru": "Открыть событие",
        "sq": "Shiko ngjarjen",
        "zh-Hans": "查看活动",
    },
    "action_center_cta_review_invite": {
        "en": "Review Invite",
        "es": "Revisar invitación",
        "fr": "Examiner l’invitation",
        "pt": "Revisar convite",
        "de": "Einladung prüfen",
        "it": "Rivedi invito",
        "pl": "Sprawdź zaproszenie",
        "ru": "Просмотреть приглашение",
        "sq": "Shqyrto ftesën",
        "zh-Hans": "查看邀请",
    },
    "action_center_cta_review_request": {
        "en": "Review Request",
        "es": "Revisar solicitud",
        "fr": "Examiner la demande",
        "pt": "Revisar pedido",
        "de": "Anfrage prüfen",
        "it": "Rivedi richiesta",
        "pl": "Sprawdź prośbę",
        "ru": "Просмотреть запрос",
        "sq": "Shqyrto kërkesën",
        "zh-Hans": "查看请求",
    },
    "action_center_friend_request_from_format": {
        "en": "%@ sent you a friend request",
        "es": "%@ te envió una solicitud de amistad",
        "fr": "%@ vous a envoyé une demande d’ami",
        "pt": "%@ enviou um pedido de amizade",
        "de": "%@ hat dir eine Freundschaftsanfrage gesendet",
        "it": "%@ ti ha inviato una richiesta di amicizia",
        "pl": "%@ wysłał(a) Ci zaproszenie do znajomych",
        "ru": "%@ отправил(а) вам заявку в друзья",
        "sq": "%@ të dërgoi një kërkesë miqësie",
        "zh-Hans": "%@ 向你发送了好友请求",
    },
    "action_center_poke_from_format": {
        "en": "%@ poked you",
        "es": "%@ te dio un toque",
        "fr": "%@ vous a envoyé un poke",
        "pt": "%@ te cutucou",
        "de": "%@ hat dich angestupst",
        "it": "%@ ti ha mandato un poke",
        "pl": "%@ Cię szturchnął(a)",
        "ru": "%@ ткнул(а) вас",
        "sq": "%@ të preku",
        "zh-Hans": "%@ 戳了你一下",
    },
    "action_center_invited_to_team_format": {
        "en": "You’re invited to %@",
        "es": "Te invitaron a %@",
        "fr": "Vous êtes invité(e) à %@",
        "pt": "Você foi convidado(a) para %@",
        "de": "Du bist zu %@ eingeladen",
        "it": "Sei invitato/a a %@",
        "pl": "Zaproszono Cię do %@",
        "ru": "Вас пригласили в %@",
        "sq": "Je ftuar në %@",
        "zh-Hans": "你受邀加入 %@",
    },
    "action_center_invited_by_format": {
        "en": "Invited by %@",
        "es": "Invitado por %@",
        "fr": "Invité par %@",
        "pt": "Convidado por %@",
        "de": "Eingeladen von %@",
        "it": "Invitato da %@",
        "pl": "Zaproszenie od %@",
        "ru": "Приглашение от %@",
        "sq": "Ftuar nga %@",
        "zh-Hans": "邀请人：%@",
    },
    "action_center_private_team": {
        "en": "Private Team",
        "es": "Equipo privado",
        "fr": "Équipe privée",
        "pt": "Equipe privada",
        "de": "Privates Team",
        "it": "Team privato",
        "pl": "Prywatny zespół",
        "ru": "Частная команда",
        "sq": "Ekip privat",
        "zh-Hans": "私人球队",
    },
    "action_center_at": {
        "en": "at",
        "es": "a las",
        "fr": "à",
        "pt": "às",
        "de": "um",
        "it": "alle",
        "pl": "o",
        "ru": "в",
        "sq": "në",
        "zh-Hans": "",
    },
}


def main() -> None:
    data = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    strings = data.setdefault("strings", {})
    added = 0
    updated = 0
    for key, values in ENTRIES.items():
        entry = {
            "extractionState": "manual",
            "localizations": locs(values["en"], {k: v for k, v in values.items() if k != "en"}),
        }
        if key in strings:
            strings[key] = entry
            updated += 1
        else:
            strings[key] = entry
            added += 1
    XCSTRINGS.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Action Center localizations: added={added} updated={updated}")


if __name__ == "__main__":
    main()
