#!/usr/bin/env python3
"""Restore missing FanGeo Inbox / Action Center keys. Does not overwrite existing translations."""
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
XCSTRINGS = ROOT / "GameOn" / "Localizable.xcstrings"
LANGS = ["en", "es", "fr", "pt", "de", "it", "pl", "ru", "sq", "zh-Hans", "nl"]

ENTRIES: dict[str, dict[str, str]] = {
    # Visible pickup-invite title. Call site passes the game title as %@.
    "action_center_pickup_invite_title": {
        "en": "You’re invited to %@",
        "es": "Te invitaron a %@",
        "fr": "Vous êtes invité(e) à %@",
        "pt": "Você foi convidado(a) para %@",
        "de": "Du bist zu %@ eingeladen",
        "it": "Sei invitato/a a %@",
        "pl": "Zaproszono Cię do %@",
        "ru": "Вас пригласили в %@",
        "sq": "Je ftuar në %@",
        "zh-Hans": "你受邀参加 %@",
        "nl": "Je bent uitgenodigd voor %@",
    },
    "action_center_pickup_invite_subtitle": {
        "en": "Review this pickup invitation.",
        "es": "Revisa esta invitación de pickup.",
        "fr": "Examinez cette invitation pickup.",
        "pt": "Revise este convite pickup.",
        "de": "Prüfe diese Pickup-Einladung.",
        "it": "Controlla questo invito pickup.",
        "pl": "Sprawdź to zaproszenie pickup.",
        "ru": "Просмотрите это пикап-приглашение.",
        "sq": "Shqyrto këtë ftesë pickup.",
        "zh-Hans": "查看此约球邀请。",
        "nl": "Bekijk deze pickupuitnodiging.",
    },
    "action_center_team_invite_title_one": {
        "en": "Team invitation",
        "es": "Invitación al equipo",
        "fr": "Invitation d’équipe",
        "pt": "Convite de equipe",
        "de": "Team-Einladung",
        "it": "Invito alla squadra",
        "pl": "Zaproszenie do drużyny",
        "ru": "Приглашение в команду",
        "sq": "Ftesë ekipi",
        "zh-Hans": "队伍邀请",
        "nl": "Teamuitnodiging",
    },
    "action_center_team_invite_title_many": {
        "en": "%@ team invitations",
        "es": "%@ invitaciones al equipo",
        "fr": "%@ invitations d’équipe",
        "pt": "%@ convites de equipe",
        "de": "%@ Team-Einladungen",
        "it": "%@ inviti alla squadra",
        "pl": "%@ zaproszenia do drużyny",
        "ru": "%@ приглашения в команду",
        "sq": "%@ ftesa ekipi",
        "zh-Hans": "%@ 个队伍邀请",
        "nl": "%@ teamuitnodigingen",
    },
    "action_center_team_invite_subtitle": {
        "en": "Review this Team invitation.",
        "es": "Revisa esta invitación al equipo.",
        "fr": "Examinez cette invitation d’équipe.",
        "pt": "Revise este convite de equipe.",
        "de": "Prüfe diese Team-Einladung.",
        "it": "Controlla questo invito alla squadra.",
        "pl": "Sprawdź to zaproszenie do drużyny.",
        "ru": "Просмотрите это приглашение в команду.",
        "sq": "Shqyrto këtë ftesë ekipi.",
        "zh-Hans": "查看此队伍邀请。",
        "nl": "Bekijk deze teamuitnodiging.",
    },
    "action_center_friend_request_title_one": {
        "en": "Friend request",
        "es": "Solicitud de amistad",
        "fr": "Demande d’ami",
        "pt": "Pedido de amizade",
        "de": "Freundschaftsanfrage",
        "it": "Richiesta di amicizia",
        "pl": "Zaproszenie do znajomych",
        "ru": "Заявка в друзья",
        "sq": "Kërkesë miqësie",
        "zh-Hans": "好友请求",
        "nl": "Vriendschapsverzoek",
    },
    "action_center_friend_request_title_many": {
        "en": "%@ friend requests",
        "es": "%@ solicitudes de amistad",
        "fr": "%@ demandes d’ami",
        "pt": "%@ pedidos de amizade",
        "de": "%@ Freundschaftsanfragen",
        "it": "%@ richieste di amicizia",
        "pl": "%@ zaproszenia do znajomych",
        "ru": "%@ заявки в друзья",
        "sq": "%@ kërkesa miqësie",
        "zh-Hans": "%@ 个好友请求",
        "nl": "%@ vriendschapsverzoeken",
    },
    "action_center_friend_request_title_format": {
        "en": "Friend request from %@",
        "es": "Solicitud de amistad de %@",
        "fr": "Demande d’ami de %@",
        "pt": "Pedido de amizade de %@",
        "de": "Freundschaftsanfrage von %@",
        "it": "Richiesta di amicizia da %@",
        "pl": "Zaproszenie do znajomych od %@",
        "ru": "Заявка в друзья от %@",
        "sq": "Kërkesë miqësie nga %@",
        "zh-Hans": "来自 %@ 的好友请求",
        "nl": "Vriendschapsverzoek van %@",
    },
    "action_center_friend_request_subtitle": {
        "en": "Review this friend request.",
        "es": "Revisa esta solicitud de amistad.",
        "fr": "Examinez cette demande d’ami.",
        "pt": "Revise este pedido de amizade.",
        "de": "Prüfe diese Freundschaftsanfrage.",
        "it": "Controlla questa richiesta di amicizia.",
        "pl": "Sprawdź to zaproszenie do znajomych.",
        "ru": "Просмотрите эту заявку в друзья.",
        "sq": "Shqyrto këtë kërkesë miqësie.",
        "zh-Hans": "查看此好友请求。",
        "nl": "Bekijk dit vriendschapsverzoek.",
    },
    "action_center_join_approval_title_one": {
        "en": "Join request",
        "es": "Solicitud para unirse",
        "fr": "Demande d’inscription",
        "pt": "Pedido para entrar",
        "de": "Beitrittsanfrage",
        "it": "Richiesta di iscrizione",
        "pl": "Prośba o dołączenie",
        "ru": "Заявка на вступление",
        "sq": "Kërkesë për t’u bashkuar",
        "zh-Hans": "加入请求",
        "nl": "Deelnameverzoek",
    },
    "action_center_join_approval_title_many": {
        "en": "%@ join requests",
        "es": "%@ solicitudes para unirse",
        "fr": "%@ demandes d’inscription",
        "pt": "%@ pedidos para entrar",
        "de": "%@ Beitrittsanfragen",
        "it": "%@ richieste di iscrizione",
        "pl": "%@ prośby o dołączenie",
        "ru": "%@ заявки на вступление",
        "sq": "%@ kërkesa për t’u bashkuar",
        "zh-Hans": "%@ 个加入请求",
        "nl": "%@ deelnameverzoeken",
    },
    "action_center_join_approval_subtitle": {
        "en": "Review who wants to join.",
        "es": "Revisa quién quiere unirse.",
        "fr": "Examinez qui souhaite rejoindre.",
        "pt": "Revise quem quer entrar.",
        "de": "Prüfe, wer beitreten möchte.",
        "it": "Controlla chi vuole unirsi.",
        "pl": "Sprawdź, kto chce dołączyć.",
        "ru": "Просмотрите, кто хочет вступить.",
        "sq": "Shqyrto kush dëshiron të bashkohet.",
        "zh-Hans": "查看谁想加入。",
        "nl": "Bekijk wie wil meedoen.",
    },
    "action_center_poke_title_one": {
        "en": "New poke",
        "es": "Nuevo toque",
        "fr": "Nouveau poke",
        "pt": "Novo toque",
        "de": "Neuer Poke",
        "it": "Nuovo poke",
        "pl": "Nowy poke",
        "ru": "Новый пок",
        "sq": "Poke i ri",
        "zh-Hans": "新的戳一下",
        "nl": "Nieuwe poke",
    },
    "action_center_poke_title_many": {
        "en": "%@ new pokes",
        "es": "%@ toques nuevos",
        "fr": "%@ nouveaux pokes",
        "pt": "%@ novos toques",
        "de": "%@ neue Pokes",
        "it": "%@ nuovi poke",
        "pl": "%@ nowe poke",
        "ru": "%@ новых пока",
        "sq": "%@ poke të reja",
        "zh-Hans": "%@ 个新戳一下",
        "nl": "%@ nieuwe pokes",
    },
    "action_center_poke_subtitle": {
        "en": "Someone poked you.",
        "es": "Alguien te dio un toque.",
        "fr": "Quelqu’un vous a envoyé un poke.",
        "pt": "Alguém te cutucou.",
        "de": "Jemand hat dich angestupst.",
        "it": "Qualcuno ti ha mandato un poke.",
        "pl": "Ktoś Cię szturchnął.",
        "ru": "Кто-то ткнул вас.",
        "sq": "Dikush të preku.",
        "zh-Hans": "有人戳了你一下。",
        "nl": "Iemand heeft je gepoked.",
    },
    "action_center_schedule_change_title_one": {
        "en": "Schedule update",
        "es": "Actualización del horario",
        "fr": "Mise à jour du calendrier",
        "pt": "Atualização da agenda",
        "de": "Termin-Update",
        "it": "Aggiornamento del programma",
        "pl": "Aktualizacja harmonogramu",
        "ru": "Обновление расписания",
        "sq": "Përditësim orari",
        "zh-Hans": "日程更新",
        "nl": "Schema-update",
    },
    "action_center_schedule_change_title_many": {
        "en": "%@ schedule updates",
        "es": "%@ actualizaciones del horario",
        "fr": "%@ mises à jour du calendrier",
        "pt": "%@ atualizações da agenda",
        "de": "%@ Termin-Updates",
        "it": "%@ aggiornamenti del programma",
        "pl": "%@ aktualizacje harmonogramu",
        "ru": "%@ обновления расписания",
        "sq": "%@ përditësime orari",
        "zh-Hans": "%@ 条日程更新",
        "nl": "%@ schema-updates",
    },
    "action_center_business_claim_title": {
        "en": "Business claim",
        "es": "Reclamo de negocio",
        "fr": "Revendication business",
        "pt": "Reivindicação business",
        "de": "Business-Anspruch",
        "it": "Richiesta business",
        "pl": "Roszczenie biznesowe",
        "ru": "Заявка бизнеса",
        "sq": "Kërkesë biznesi",
        "zh-Hans": "商家认领",
        "nl": "Bedrijfsclaim",
    },
    "action_center_business_claim_subtitle": {
        "en": "Review this business claim.",
        "es": "Revisa este reclamo de negocio.",
        "fr": "Examinez cette revendication business.",
        "pt": "Revise esta reivindicação business.",
        "de": "Prüfe diesen Business-Anspruch.",
        "it": "Controlla questa richiesta business.",
        "pl": "Sprawdź to roszczenie biznesowe.",
        "ru": "Просмотрите эту заявку бизнеса.",
        "sq": "Shqyrto këtë kërkesë biznesi.",
        "zh-Hans": "查看此商家认领。",
        "nl": "Bekijk deze bedrijfsclaim.",
    },
    "action_center_change_date": {
        "en": "Date changed",
        "es": "Fecha cambiada",
        "fr": "Date modifiée",
        "pt": "Data alterada",
        "de": "Datum geändert",
        "it": "Data modificata",
        "pl": "Zmieniono datę",
        "ru": "Дата изменена",
        "sq": "Data u ndryshua",
        "zh-Hans": "日期已更改",
        "nl": "Datum gewijzigd",
    },
    "action_center_change_opponent": {
        "en": "Opponent changed",
        "es": "Rival cambiado",
        "fr": "Adversaire modifié",
        "pt": "Adversário alterado",
        "de": "Gegner geändert",
        "it": "Avversario modificato",
        "pl": "Zmieniono przeciwnika",
        "ru": "Соперник изменён",
        "sq": "Kundërshtari u ndryshua",
        "zh-Hans": "对手已更改",
        "nl": "Tegenstander gewijzigd",
    },
    "action_center_change_status": {
        "en": "Status changed",
        "es": "Estado cambiado",
        "fr": "Statut modifié",
        "pt": "Status alterado",
        "de": "Status geändert",
        "it": "Stato modificato",
        "pl": "Zmieniono status",
        "ru": "Статус изменён",
        "sq": "Statusi u ndryshua",
        "zh-Hans": "状态已更改",
        "nl": "Status gewijzigd",
    },
}


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def upsert(strings: dict, key: str, translations: dict[str, str]) -> None:
    entry = strings.get(key, {"extractionState": "manual", "localizations": {}})
    entry["extractionState"] = "manual"
    locs = entry.setdefault("localizations", {})
    for lang in LANGS:
        value = translations.get(lang, translations["en"])
        existing = locs.get(lang, {}).get("stringUnit", {}).get("value")
        if not existing:
            locs[lang] = unit(value)
    strings[key] = entry


def main() -> None:
    data = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    strings = data.setdefault("strings", {})
    for key, translations in ENTRIES.items():
        upsert(strings, key, translations)
    XCSTRINGS.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"upserted {len(ENTRIES)} Inbox Action Center keys")


if __name__ == "__main__":
    main()
