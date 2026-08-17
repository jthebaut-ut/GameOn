#!/usr/bin/env python3
"""Localization for the FanGeo Inbox onboarding guide page."""
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
    "guide_inbox_primary": {
        "en": "Never miss what's happening in FanGeo.",
        "es": "No te pierdas lo que ocurre en FanGeo.",
        "fr": "Ne manquez rien de ce qui se passe sur FanGeo.",
        "pt": "Não perca o que está acontecendo no FanGeo.",
        "de": "Verpasse nichts, was in FanGeo passiert.",
        "it": "Non perdere ciò che accade su FanGeo.",
        "pl": "Nie przegap tego, co dzieje się w FanGeo.",
        "ru": "Не пропускайте то, что происходит в FanGeo.",
        "sq": "Mos humb asgjë nga çfarë ndodh në FanGeo.",
        "zh-Hans": "不错过 FanGeo 里正在发生的事。",
        "nl": "Mis nooit wat er in FanGeo gebeurt.",
    },
    "guide_inbox_bullet_1": {
        "en": "Action items that need your attention",
        "es": "Acciones que necesitan tu atención",
        "fr": "Actions qui demandent votre attention",
        "pt": "Ações que precisam da sua atenção",
        "de": "Aktionen, die deine Aufmerksamkeit brauchen",
        "it": "Azioni che richiedono la tua attenzione",
        "pl": "Działania wymagające Twojej uwagi",
        "ru": "Действия, требующие вашего внимания",
        "sq": "Veprime që kërkojnë vëmendjen tuaj",
        "zh-Hans": "需要你处理的待办事项",
        "nl": "Acties die jouw aandacht nodig hebben",
    },
    "guide_inbox_bullet_2": {
        "en": "Team updates and announcements",
        "es": "Actualizaciones y anuncios del equipo",
        "fr": "Mises à jour et annonces d’équipe",
        "pt": "Atualizações e anúncios da equipe",
        "de": "Team-Updates und Ankündigungen",
        "it": "Aggiornamenti e annunci del team",
        "pl": "Aktualizacje i ogłoszenia drużyny",
        "ru": "Обновления и объявления команды",
        "sq": "Përditësime dhe njoftime të ekipit",
        "zh-Hans": "球队动态与公告",
        "nl": "Teamupdates en mededelingen",
    },
    "guide_inbox_bullet_3": {
        "en": "Invitations and join requests",
        "es": "Invitaciones y solicitudes para unirse",
        "fr": "Invitations et demandes d’adhésion",
        "pt": "Convites e pedidos para entrar",
        "de": "Einladungen und Beitrittsanfragen",
        "it": "Inviti e richieste di partecipazione",
        "pl": "Zaproszenia i prośby o dołączenie",
        "ru": "Приглашения и запросы на вступление",
        "sq": "Ftesa dhe kërkesa për t’u bashkuar",
        "zh-Hans": "邀请与加入申请",
        "nl": "Uitnodigingen en deelnameverzoeken",
    },
    "guide_inbox_bullet_4": {
        "en": "Game reminders and schedule changes",
        "es": "Recordatorios de partidos y cambios de horario",
        "fr": "Rappels de match et changements d’horaire",
        "pt": "Lembretes de jogos e mudanças de horário",
        "de": "Spiel-Erinnerungen und Terminänderungen",
        "it": "Promemoria partite e cambi di orario",
        "pl": "Przypomnienia o meczach i zmiany w harmonogramie",
        "ru": "Напоминания об играх и изменения расписания",
        "sq": "Kujtesa lojërash dhe ndryshime orari",
        "zh-Hans": "比赛提醒与赛程变更",
        "nl": "Wedstrijdherinneringen en schemawijzigingen",
    },
    "guide_inbox_bullet_5": {
        "en": "Notification history in one place",
        "es": "Historial de notificaciones en un solo lugar",
        "fr": "L’historique des notifications au même endroit",
        "pt": "Histórico de notificações em um só lugar",
        "de": "Benachrichtigungsverlauf an einem Ort",
        "it": "Cronologia delle notifiche in un unico posto",
        "pl": "Historia powiadomień w jednym miejscu",
        "ru": "История уведомлений в одном месте",
        "sq": "Historia e njoftimeve në një vend",
        "zh-Hans": "通知历史集中在一处",
        "nl": "Notificatiegeschiedenis op één plek",
    },
    "guide_inbox_hero_a11y": {
        "en": "Illustration of FanGeo Inbox with team invitations, game invites, friend requests, announcements, and reminders in one activity hub.",
        "es": "Ilustración de Bandeja FanGeo con invitaciones de equipo, convites a partidos, solicitudes de amistad, anuncios y recordatorios en un solo centro de actividad.",
        "fr": "Illustration de la boîte de réception FanGeo avec invitations d’équipe, invitations de match, demandes d’amis, annonces et rappels dans un même espace d’activité.",
        "pt": "Ilustração da caixa de entrada FanGeo com convites de equipe, convites de jogos, pedidos de amizade, anúncios e lembretes em um só hub de atividade.",
        "de": "Illustration des FanGeo-Posteingangs mit Team-Einladungen, Spiel-Einladungen, Freundschaftsanfragen, Ankündigungen und Erinnerungen in einem Aktivitäts-Hub.",
        "it": "Illustrazione della posta in arrivo FanGeo con inviti di squadra, inviti di partita, richieste di amicizia, annunci e promemoria in un unico hub di attività.",
        "pl": "Ilustracja Skrzynki FanGeo z zaproszeniami do drużyny, zaproszeniami na mecze, zaproszeniami do znajomych, ogłoszeniami i przypomnieniami w jednym centrum aktywności.",
        "ru": "Иллюстрация входящих FanGeo: приглашения в команду, приглашения на игры, заявки в друзья, объявления и напоминания в одном центре активности.",
        "sq": "Ilustrim i Inbox FanGeo me ftesa ekipi, ftesa lojërash, kërkesa miqësie, njoftime dhe kujtesa në një qendër aktiviteti.",
        "zh-Hans": "FanGeo 收件箱插图：球队邀请、比赛邀请、好友请求、公告和提醒集中在一个动态中心。",
        "nl": "Illustratie van de FanGeo-inbox met teamuitnodigingen, wedstrijduitnodigingen, vriendschapsverzoeken, mededelingen en herinneringen in één activiteitenhub.",
    },
    "guide_inbox_bullets_a11y": {
        "en": "FanGeo Inbox includes action items, team updates, invitations, game reminders, and notification history.",
        "es": "Bandeja FanGeo incluye acciones pendientes, actualizaciones del equipo, invitaciones, recordatorios de partidos e historial de notificaciones.",
        "fr": "La boîte de réception FanGeo regroupe les actions à traiter, les mises à jour d’équipe, les invitations, les rappels de match et l’historique des notifications.",
        "pt": "A caixa de entrada FanGeo inclui ações pendentes, atualizações da equipe, convites, lembretes de jogos e histórico de notificações.",
        "de": "Der FanGeo-Posteingang enthält Aktionen, Team-Updates, Einladungen, Spiel-Erinnerungen und den Benachrichtigungsverlauf.",
        "it": "La posta in arrivo FanGeo include azioni da completare, aggiornamenti del team, inviti, promemoria delle partite e la cronologia delle notifiche.",
        "pl": "Skrzynka FanGeo zawiera działania do wykonania, aktualizacje drużyny, zaproszenia, przypomnienia o meczach i historię powiadomień.",
        "ru": "Во входящих FanGeo — задачи, обновления команды, приглашения, напоминания об играх и история уведомлений.",
        "sq": "Inbox FanGeo përfshin veprime, përditësime ekipi, ftesa, kujtesa lojërash dhe historinë e njoftimeve.",
        "zh-Hans": "FanGeo 收件箱包含待办事项、球队动态、邀请、比赛提醒和通知历史。",
        "nl": "De FanGeo-inbox bevat actie-items, teamupdates, uitnodigingen, wedstrijdherinneringen en notificatiegeschiedenis.",
    },
    "guide_inbox_demo_team_invite": {
        "en": "Team invitation",
        "es": "Invitación de equipo",
        "fr": "Invitation d’équipe",
        "pt": "Convite de equipe",
        "de": "Team-Einladung",
        "it": "Invito di squadra",
        "pl": "Zaproszenie do drużyny",
        "ru": "Приглашение в команду",
        "sq": "Ftesë ekipi",
        "zh-Hans": "球队邀请",
        "nl": "Teamuitnodiging",
    },
    "guide_inbox_demo_game_invite": {
        "en": "Game invitation",
        "es": "Invitación a un partido",
        "fr": "Invitation de match",
        "pt": "Convite de jogo",
        "de": "Spiel-Einladung",
        "it": "Invito di partita",
        "pl": "Zaproszenie na mecz",
        "ru": "Приглашение на игру",
        "sq": "Ftesë loje",
        "zh-Hans": "比赛邀请",
        "nl": "Wedstrijduitnodiging",
    },
    "guide_inbox_demo_friend": {
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
    "guide_inbox_demo_announcement": {
        "en": "Team announcement",
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
    "guide_inbox_demo_reminder": {
        "en": "Game reminder",
        "es": "Recordatorio de partido",
        "fr": "Rappel de match",
        "pt": "Lembrete de jogo",
        "de": "Spiel-Erinnerung",
        "it": "Promemoria partita",
        "pl": "Przypomnienie o meczu",
        "ru": "Напоминание об игре",
        "sq": "Kujtesë loje",
        "zh-Hans": "比赛提醒",
        "nl": "Wedstrijdherinnering",
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
    print(f"patched {len(ENTRIES)} FanGeo Inbox onboarding keys")


if __name__ == "__main__":
    main()
