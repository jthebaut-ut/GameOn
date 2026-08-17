#!/usr/bin/env python3
"""Localization for Going → Play Create Game + Filter mockup."""
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
    "going_play_filter": {
        "en": "Filter",
        "es": "Filtro",
        "fr": "Filtrer",
        "pt": "Filtro",
        "de": "Filter",
        "it": "Filtro",
        "pl": "Filtr",
        "ru": "Фильтр",
        "sq": "Filtro",
        "zh-Hans": "筛选",
    },
    "going_play_filter_all": {
        "en": "All",
        "es": "Todo",
        "fr": "Tout",
        "pt": "Tudo",
        "de": "Alle",
        "it": "Tutti",
        "pl": "Wszystko",
        "ru": "Все",
        "sq": "Të gjitha",
        "zh-Hans": "全部",
    },
    "going_play_filter_hosting": {
        "en": "Hosting",
        "es": "Organizando",
        "fr": "Organisation",
        "pt": "Organizando",
        "de": "Hosting",
        "it": "Organizzazione",
        "pl": "Organizowane",
        "ru": "Организую",
        "sq": "Organizim",
        "zh-Hans": "主办",
    },
    "going_play_filter_invites": {
        "en": "Invites",
        "es": "Invitaciones",
        "fr": "Invitations",
        "pt": "Convites",
        "de": "Einladungen",
        "it": "Inviti",
        "pl": "Zaproszenia",
        "ru": "Приглашения",
        "sq": "Ftesa",
        "zh-Hans": "邀请",
    },
    "going_play_filter_pickups": {
        "en": "Pickups",
        "es": "Pickups",
        "fr": "Pickups",
        "pt": "Pickups",
        "de": "Pickups",
        "it": "Pickup",
        "pl": "Pickupy",
        "ru": "Pickup",
        "sq": "Pickup",
        "zh-Hans": "Pickup",
    },
    "going_play_filter_team_events": {
        "en": "Team Events",
        "es": "Eventos de equipo",
        "fr": "Événements d’équipe",
        "pt": "Eventos de equipe",
        "de": "Team-Events",
        "it": "Eventi di squadra",
        "pl": "Wydarzenia drużyny",
        "ru": "События команды",
        "sq": "Evente ekipi",
        "zh-Hans": "队伍活动",
    },
    "going_play_filter_a11y_format": {
        "en": "Filter, %@",
        "es": "Filtro, %@",
        "fr": "Filtrer, %@",
        "pt": "Filtro, %@",
        "de": "Filter, %@",
        "it": "Filtro, %@",
        "pl": "Filtr, %@",
        "ru": "Фильтр, %@",
        "sq": "Filtro, %@",
        "zh-Hans": "筛选，%@",
    },
    "going_play_badge_pickup": {
        "en": "PICKUP",
        "es": "PICKUP",
        "fr": "PICKUP",
        "pt": "PICKUP",
        "de": "PICKUP",
        "it": "PICKUP",
        "pl": "PICKUP",
        "ru": "PICKUP",
        "sq": "PICKUP",
        "zh-Hans": "PICKUP",
    },
    "going_play_badge_team": {
        "en": "TEAM",
        "es": "EQUIPO",
        "fr": "ÉQUIPE",
        "pt": "EQUIPE",
        "de": "TEAM",
        "it": "TEAM",
        "pl": "DRUŻYNA",
        "ru": "КОМАНДА",
        "sq": "EKIP",
        "zh-Hans": "队伍",
    },
    "going_play_empty_all": {
        "en": "Nothing on your Play list yet.",
        "es": "Todavía no hay nada en tu lista de Play.",
        "fr": "Rien pour l’instant dans votre liste Play.",
        "pt": "Ainda não há nada na sua lista Play.",
        "de": "Auf deiner Play-Liste steht noch nichts.",
        "it": "Non c’è ancora nulla nella tua lista Play.",
        "pl": "Twoja lista Play jest jeszcze pusta.",
        "ru": "В списке Play пока ничего нет.",
        "sq": "Lista Play është ende bosh.",
        "zh-Hans": "你的 Play 列表还是空的。",
    },
    "going_play_empty_all_supporting": {
        "en": "Join a pickup, RSVP Going on a Team event, or create a game.",
        "es": "Únete a un pickup, confirma asistencia a un evento de equipo o crea un juego.",
        "fr": "Rejoignez un pickup, confirmez votre présence à un événement d’équipe ou créez un jeu.",
        "pt": "Entre em um pickup, confirme presença em um evento de equipe ou crie um jogo.",
        "de": "Tritt einem Pickup bei, sage bei einem Team-Event „Going“ oder erstelle ein Spiel.",
        "it": "Unisciti a un pickup, conferma la partecipazione a un evento di squadra o crea una partita.",
        "pl": "Dołącz do pickupu, potwierdź udział w wydarzeniu drużyny albo utwórz grę.",
        "ru": "Присоединитесь к pickup, подтвердите участие в событии команды или создайте игру.",
        "sq": "Bashkohu në një pickup, konfirmo pjesëmarrjen në një event ekipi ose krijo një lojë.",
        "zh-Hans": "加入 Pickup、在队伍活动中回复参加，或创建一场活动。",
    },
    "going_play_empty_pickups": {
        "en": "No pickups on your list.",
        "es": "No hay pickups en tu lista.",
        "fr": "Aucun pickup dans votre liste.",
        "pt": "Nenhum pickup na sua lista.",
        "de": "Keine Pickups auf deiner Liste.",
        "it": "Nessun pickup nella tua lista.",
        "pl": "Brak pickupów na liście.",
        "ru": "В списке нет pickup.",
        "sq": "Nuk ka pickup në listë.",
        "zh-Hans": "列表里没有 Pickup。",
    },
    "going_play_empty_pickups_supporting": {
        "en": "Join or create a pickup to see it here.",
        "es": "Únete o crea un pickup para verlo aquí.",
        "fr": "Rejoignez ou créez un pickup pour le voir ici.",
        "pt": "Entre ou crie um pickup para vê-lo aqui.",
        "de": "Tritt einem Pickup bei oder erstelle eines, um es hier zu sehen.",
        "it": "Unisciti a un pickup o creane uno per vederlo qui.",
        "pl": "Dołącz do pickupu lub utwórz go, aby zobaczyć go tutaj.",
        "ru": "Присоединитесь к pickup или создайте его, чтобы увидеть здесь.",
        "sq": "Bashkohu ose krijo një pickup për ta parë këtu.",
        "zh-Hans": "加入或创建 Pickup 后就会显示在这里。",
    },
    "going_play_empty_team_events": {
        "en": "No Team events on your list.",
        "es": "No hay eventos de equipo en tu lista.",
        "fr": "Aucun événement d’équipe dans votre liste.",
        "pt": "Nenhum evento de equipe na sua lista.",
        "de": "Keine Team-Events auf deiner Liste.",
        "it": "Nessun evento di squadra nella tua lista.",
        "pl": "Brak wydarzeń drużyny na liście.",
        "ru": "В списке нет событий команды.",
        "sq": "Nuk ka evente ekipi në listë.",
        "zh-Hans": "列表里没有队伍活动。",
    },
    "going_play_empty_team_events_supporting": {
        "en": "RSVP Going on a Team practice, match, or ride to see it here.",
        "es": "Confirma asistencia a un entrenamiento, partido o salida de equipo para verlo aquí.",
        "fr": "Confirmez votre présence à un entraînement, un match ou une sortie d’équipe pour le voir ici.",
        "pt": "Confirme presença em um treino, jogo ou pedal de equipe para ver aqui.",
        "de": "Sage bei einem Team-Training, Spiel oder Ride „Going“, um es hier zu sehen.",
        "it": "Conferma la partecipazione a un allenamento, una partita o un’uscita di squadra per vederla qui.",
        "pl": "Potwierdź udział w treningu, meczu lub przejażdżce drużyny, aby zobaczyć je tutaj.",
        "ru": "Подтвердите участие в тренировке, матче или заезде команды, чтобы увидеть его здесь.",
        "sq": "Konfirmo pjesëmarrjen në një stërvitje, ndeshje ose vozitje ekipi për ta parë këtu.",
        "zh-Hans": "在队伍训练、比赛或骑行中回复参加后，就会显示在这里。",
    },
    "going_play_declined_request_caption": {
        "en": "The organizer declined this request. You can clear it from Going.",
        "es": "El organizador rechazó esta solicitud. Puedes quitarla de Going.",
        "fr": "L’organisateur a refusé cette demande. Vous pouvez la retirer de Going.",
        "pt": "O organizador recusou este pedido. Você pode removê-lo de Going.",
        "de": "Der Organizer hat diese Anfrage abgelehnt. Du kannst sie aus Going entfernen.",
        "it": "L’organizzatore ha rifiutato questa richiesta. Puoi rimuoverla da Going.",
        "pl": "Organizator odrzucił tę prośbę. Możesz usunąć ją z Going.",
        "ru": "Организатор отклонил заявку. Её можно убрать из Going.",
        "sq": "Organizatori e refuzoi këtë kërkesë. Mund ta heqësh nga Going.",
        "zh-Hans": "组织者拒绝了该申请。你可以从 Going 中清除它。",
    },
}


def main() -> None:
    data = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    strings = data.setdefault("strings", {})
    for key, translations in ENTRIES.items():
        strings[key] = {
            "extractionState": "manual",
            "localizations": locs(translations["en"], translations),
        }
    XCSTRINGS.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"patched {len(ENTRIES)} Going Play filter keys")


if __name__ == "__main__":
    main()
