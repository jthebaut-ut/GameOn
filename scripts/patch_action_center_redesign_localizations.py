#!/usr/bin/env python3
"""Localization for redesigned Action Center presentation."""
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
    "action_center_subtitle": {
        "en": "Your actions, updates, and notification history.",
        "es": "Tus acciones, actualizaciones e historial de notificaciones.",
        "fr": "Vos actions, mises à jour et historique de notifications.",
        "pt": "Suas ações, atualizações e histórico de notificações.",
        "de": "Deine Aktionen, Updates und dein Benachrichtigungsverlauf.",
        "it": "Le tue azioni, gli aggiornamenti e la cronologia delle notifiche.",
        "pl": "Twoje działania, aktualizacje i historia powiadomień.",
        "ru": "Ваши действия, обновления и история уведомлений.",
        "sq": "Veprimet, përditësimet dhe historia e njoftimeve tuaja.",
        "zh-Hans": "你的待办、动态与通知历史。",
    },
    "action_center_section_action_required": {
        "en": "Action Required",
        "es": "Acción requerida",
        "fr": "Action requise",
        "pt": "Ação necessária",
        "de": "Aktion erforderlich",
        "it": "Azione richiesta",
        "pl": "Wymagane działanie",
        "ru": "Требуется действие",
        "sq": "Kërkohet veprim",
        "zh-Hans": "需要操作",
    },
    "action_center_section_action_required_subtitle": {
        "en": "Requires your attention.",
        "es": "Requiere tu atención.",
        "fr": "Nécessite votre attention.",
        "pt": "Requer sua atenção.",
        "de": "Erfordert deine Aufmerksamkeit.",
        "it": "Richiede la tua attenzione.",
        "pl": "Wymaga Twojej uwagi.",
        "ru": "Требует вашего внимания.",
        "sq": "Kërkon vëmendjen tuaj.",
        "zh-Hans": "需要你处理。",
    },
    "action_center_section_fyi": {
        "en": "For Your Information",
        "es": "Para tu información",
        "fr": "Pour information",
        "pt": "Para sua informação",
        "de": "Zur Information",
        "it": "Per tua informazione",
        "pl": "Na twoją wiedzę",
        "ru": "К сведению",
        "sq": "Për informacion",
        "zh-Hans": "供你参考",
    },
    "action_center_section_fyi_subtitle": {
        "en": "Recent updates that don’t require action.",
        "es": "Actualizaciones recientes que no requieren acción.",
        "fr": "Mises à jour récentes sans action requise.",
        "pt": "Atualizações recentes que não exigem ação.",
        "de": "Aktuelle Updates ohne Handlungsbedarf.",
        "it": "Aggiornamenti recenti che non richiedono azione.",
        "pl": "Ostatnie aktualizacje bez wymaganej akcji.",
        "ru": "Недавние обновления без обязательных действий.",
        "sq": "Përditësime të fundit që nuk kërkojnë veprim.",
        "zh-Hans": "无需操作的近期更新。",
    },
    "action_center_caught_up_title": {
        "en": "You’re all caught up!",
        "es": "¡Estás al día!",
        "fr": "Vous êtes à jour !",
        "pt": "Você está em dia!",
        "de": "Du bist auf dem Laufenden!",
        "it": "Sei in pari!",
        "pl": "Jesteś na bieżąco!",
        "ru": "Вы всё сделали!",
        "sq": "Je plotësisht i përditësuar!",
        "zh-Hans": "全部处理完毕！",
    },
    "action_center_caught_up_body": {
        "en": "No pending approvals.\nNo invitations waiting.\nYou’re ready for your next game.",
        "es": "Sin aprobaciones pendientes.\nSin invitaciones en espera.\nListo para tu próximo partido.",
        "fr": "Aucune approbation en attente.\nAucune invitation en attente.\nPrêt pour votre prochain match.",
        "pt": "Nenhuma aprovação pendente.\nNenhum convite aguardando.\nPronto para o próximo jogo.",
        "de": "Keine offenen Freigaben.\nKeine wartenden Einladungen.\nBereit für dein nächstes Spiel.",
        "it": "Nessuna approvazione in sospeso.\nNessun invito in attesa.\nPronto per la prossima partita.",
        "pl": "Brak oczekujących zatwierdzeń.\nBrak oczekujących zaproszeń.\nGotowy na kolejną grę.",
        "ru": "Нет ожидающих одобрений.\nНет ожидающих приглашений.\nВы готовы к следующей игре.",
        "sq": "Nuk ka miratime në pritje.\nNuk ka ftesa në pritje.\nJe gati për lojën tënde të radhës.",
        "zh-Hans": "没有待审批。\n没有待处理邀请。\n可以准备下一场比赛了。",
    },
    "action_center_badge_join_request": {
        "en": "JOIN REQUEST",
        "es": "SOLICITUD",
        "fr": "DEMANDE",
        "pt": "PEDIDO",
        "de": "ANFRAGE",
        "it": "RICHIESTA",
        "pl": "PROŚBA",
        "ru": "ЗАПРОС",
        "sq": "KËRKESË",
        "zh-Hans": "加入请求",
    },
    "action_center_badge_event_updated": {
        "en": "EVENT UPDATED",
        "es": "EVENTO ACTUALIZADO",
        "fr": "ÉVÉNEMENT MIS À JOUR",
        "pt": "EVENTO ATUALIZADO",
        "de": "EVENT AKTUALISIERT",
        "it": "EVENTO AGGIORNATO",
        "pl": "EVENT ZAKTUALIZOWANY",
        "ru": "СОБЫТИЕ ОБНОВЛЕНО",
        "sq": "NGJARJA U PËRDITËSUA",
        "zh-Hans": "活动已更新",
    },
    "action_center_badge_event_cancelled": {
        "en": "EVENT CANCELLED",
        "es": "EVENTO CANCELADO",
        "fr": "ÉVÉNEMENT ANNULÉ",
        "pt": "EVENTO CANCELADO",
        "de": "EVENT ABGESAGT",
        "it": "EVENTO ANNULLATO",
        "pl": "EVENT ODWOŁANY",
        "ru": "СОБЫТИЕ ОТМЕНЕНО",
        "sq": "NGJARJA U ANULUA",
        "zh-Hans": "活动已取消",
    },
    "action_center_badge_friend_request": {
        "en": "FRIEND REQUEST",
        "es": "SOLICITUD DE AMISTAD",
        "fr": "DEMANDE D’AMI",
        "pt": "PEDIDO DE AMIZADE",
        "de": "FREUNDSCHAFTSANFRAGE",
        "it": "RICHIESTA DI AMICIZIA",
        "pl": "ZAPROSZENIE DO ZNAJOMYCH",
        "ru": "ЗАЯВКА В ДРУЗЬЯ",
        "sq": "KËRKESË MIQËSIE",
        "zh-Hans": "好友请求",
    },
    "action_center_badge_team_invite": {
        "en": "TEAM INVITE",
        "es": "INVITACIÓN AL EQUIPO",
        "fr": "INVITATION D’ÉQUIPE",
        "pt": "CONVITE DE EQUIPE",
        "de": "TEAM-EINLADUNG",
        "it": "INVITO ALLA SQUADRA",
        "pl": "ZAPROSZENIE DO DRUŻYNY",
        "ru": "ПРИГЛАШЕНИЕ В КОМАНДУ",
        "sq": "FTESË EKIPI",
        "zh-Hans": "队伍邀请",
    },
    "action_center_badge_pickup_invite": {
        "en": "GAME INVITE",
        "es": "INVITACIÓN AL PARTIDO",
        "fr": "INVITATION AU MATCH",
        "pt": "CONVITE PARA JOGO",
        "de": "SPIEL-EINLADUNG",
        "it": "INVITO ALLA PARTITA",
        "pl": "ZAPROSZENIE DO GRY",
        "ru": "ПРИГЛАШЕНИЕ НА ИГРУ",
        "sq": "FTESË LOJE",
        "zh-Hans": "比赛邀请",
    },
    "action_center_badge_rate_game": {
        "en": "RATE GAME",
        "es": "VALORAR PARTIDO",
        "fr": "NOTER LE MATCH",
        "pt": "AVALIAR JOGO",
        "de": "SPIEL BEWERTEN",
        "it": "VALUTA PARTITA",
        "pl": "OCEŃ GRĘ",
        "ru": "ОЦЕНИТЬ ИГРУ",
        "sq": "VLERËSO LOJËN",
        "zh-Hans": "评价比赛",
    },
    "action_center_badge_poke": {
        "en": "POKE",
        "es": "TOQUE",
        "fr": "POKE",
        "pt": "TOQUE",
        "de": "ANSTUPSEN",
        "it": "POKE",
        "pl": "POKE",
        "ru": "ПОК",
        "sq": "POKE",
        "zh-Hans": "戳一下",
    },
    "action_center_badge_business_claim": {
        "en": "BUSINESS CLAIM",
        "es": "RECLAMO DE NEGOCIO",
        "fr": "REVENDICATION BUSINESS",
        "pt": "REIVINDICAÇÃO BUSINESS",
        "de": "BUSINESS-ANSPRUCH",
        "it": "RICHIESTA BUSINESS",
        "pl": "ROSZCZENIE BIZNESOWE",
        "ru": "ЗАЯВКА БИЗНЕСА",
        "sq": "KËRKESË BIZNESI",
        "zh-Hans": "商家认领",
    },
    "action_center_time_just_now": {
        "en": "Just now",
        "es": "Justo ahora",
        "fr": "À l’instant",
        "pt": "Agora mesmo",
        "de": "Gerade eben",
        "it": "Proprio ora",
        "pl": "Przed chwilą",
        "ru": "Только что",
        "sq": "Tani",
        "zh-Hans": "刚刚",
    },
    "action_center_time_minutes_ago_format": {
        "en": "%lldm ago",
        "es": "hace %lld min",
        "fr": "il y a %lld min",
        "pt": "há %lld min",
        "de": "vor %lld Min.",
        "it": "%lld min fa",
        "pl": "%lld min temu",
        "ru": "%lld мин назад",
        "sq": "%lld min më parë",
        "zh-Hans": "%lld 分钟前",
    },
    "action_center_time_today": {
        "en": "Today",
        "es": "Hoy",
        "fr": "Aujourd’hui",
        "pt": "Hoje",
        "de": "Heute",
        "it": "Oggi",
        "pl": "Dziś",
        "ru": "Сегодня",
        "sq": "Sot",
        "zh-Hans": "今天",
    },
    "action_center_time_yesterday": {
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
