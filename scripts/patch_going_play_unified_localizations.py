#!/usr/bin/env python3
"""Localization for Going → Play unified Pickup + Team feed."""
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
    "going_play_empty_playing": {
        "en": "Nothing you're playing yet.",
        "es": "Todavía no estás jugando nada.",
        "fr": "Vous ne jouez encore à rien.",
        "pt": "Você ainda não está jogando nada.",
        "de": "Du spielst noch nichts.",
        "it": "Non stai ancora giocando a nulla.",
        "pl": "Jeszcze w nic nie grasz.",
        "ru": "Вы пока ни в чём не участвуете.",
        "sq": "Nuk po luan asgjë ende.",
        "zh-Hans": "你还没有要参加的活动。",
    },
    "going_play_empty_playing_supporting": {
        "en": "Join a pickup or RSVP Going on a Team event to see it here.",
        "es": "Únete a un pickup o confirma asistencia a un evento de equipo para verlo aquí.",
        "fr": "Rejoignez un pickup ou confirmez votre présence à un événement d’équipe pour le voir ici.",
        "pt": "Entre em um pickup ou confirme presença em um evento de equipe para ver aqui.",
        "de": "Tritt einem Pickup bei oder sage bei einem Team-Event „Going“, um es hier zu sehen.",
        "it": "Unisciti a un pickup o conferma la partecipazione a un evento di squadra per vederlo qui.",
        "pl": "Dołącz do pickupu lub potwierdź udział w wydarzeniu drużyny, aby zobaczyć je tutaj.",
        "ru": "Присоединитесь к pickup или подтвердите участие в событии команды, чтобы увидеть его здесь.",
        "sq": "Bashkohu në një pickup ose konfirmo pjesëmarrjen në një event ekipi për ta parë këtu.",
        "zh-Hans": "加入 Pickup 或在队伍活动中回复参加后，就会显示在这里。",
    },
    "going_play_empty_hosting": {
        "en": "Nothing you're hosting yet.",
        "es": "Todavía no estás organizando nada.",
        "fr": "Vous n’organisez encore rien.",
        "pt": "Você ainda não está organizando nada.",
        "de": "Du veranstaltest noch nichts.",
        "it": "Non stai ancora organizzando nulla.",
        "pl": "Jeszcze niczego nie organizujesz.",
        "ru": "Вы пока ничего не организуете.",
        "sq": "Nuk po organizon asgjë ende.",
        "zh-Hans": "你还没有主办的活动。",
    },
    "going_play_empty_hosting_supporting": {
        "en": "Create a pickup or schedule a Team event you manage.",
        "es": "Crea un pickup o programa un evento de equipo que gestiones.",
        "fr": "Créez un pickup ou planifiez un événement d’équipe que vous gérez.",
        "pt": "Crie um pickup ou agende um evento de equipe que você gerencia.",
        "de": "Erstelle ein Pickup oder plane ein Team-Event, das du verwaltest.",
        "it": "Crea un pickup o programma un evento di squadra che gestisci.",
        "pl": "Utwórz pickup lub zaplanuj wydarzenie drużyny, którym zarządzasz.",
        "ru": "Создайте pickup или запланируйте событие команды, которым вы управляете.",
        "sq": "Krijo një pickup ose planifiko një event ekipi që menaxhon.",
        "zh-Hans": "创建一个 Pickup，或安排你管理的队伍活动。",
    },
    "going_play_empty_invites": {
        "en": "No play invites right now.",
        "es": "No hay invitaciones para jugar ahora.",
        "fr": "Aucune invitation à jouer pour le moment.",
        "pt": "Nenhum convite para jogar agora.",
        "de": "Gerade keine Spiel-Einladungen.",
        "it": "Nessun invito a giocare in questo momento.",
        "pl": "Brak zaproszeń do gry.",
        "ru": "Сейчас нет приглашений поиграть.",
        "sq": "Nuk ka ftesa për të luajtur tani.",
        "zh-Hans": "目前没有活动邀请。",
    },
    "going_play_empty_invites_supporting": {
        "en": "Invitations from friends and organizers will appear here.",
        "es": "Las invitaciones de amigos y organizadores aparecerán aquí.",
        "fr": "Les invitations d’amis et d’organisateurs apparaîtront ici.",
        "pt": "Convites de amigos e organizadores aparecerão aqui.",
        "de": "Einladungen von Freunden und Organisatoren erscheinen hier.",
        "it": "Gli inviti di amici e organizzatori appariranno qui.",
        "pl": "Zaproszenia od znajomych i organizatorów pojawią się tutaj.",
        "ru": "Приглашения от друзей и организаторов появятся здесь.",
        "sq": "Ftesat nga miqtë dhe organizatorët do të shfaqen këtu.",
        "zh-Hans": "来自好友和组织者的邀请会显示在这里。",
    },
    "going_play_upcoming": {
        "en": "Upcoming",
        "es": "Próximos",
        "fr": "À venir",
        "pt": "Próximos",
        "de": "Bevorstehend",
        "it": "In arrivo",
        "pl": "Nadchodzące",
        "ru": "Предстоящие",
        "sq": "Së shpejti",
        "zh-Hans": "即将开始",
    },
    "going_play_a11y_pickup": {
        "en": "Pickup",
        "es": "Pickup",
        "fr": "Pickup",
        "pt": "Pickup",
        "de": "Pickup",
        "it": "Pickup",
        "pl": "Pickup",
        "ru": "Pickup",
        "sq": "Pickup",
        "zh-Hans": "Pickup",
    },
    "going_play_a11y_team": {
        "en": "Team",
        "es": "Equipo",
        "fr": "Équipe",
        "pt": "Equipe",
        "de": "Team",
        "it": "Squadra",
        "pl": "Drużyna",
        "ru": "Команда",
        "sq": "Ekip",
        "zh-Hans": "队伍",
    },
    "going_play_status_invited": {
        "en": "Invited",
        "es": "Invitado",
        "fr": "Invité",
        "pt": "Convidado",
        "de": "Eingeladen",
        "it": "Invitato",
        "pl": "Zaproszony",
        "ru": "Приглашён",
        "sq": "I ftuar",
        "zh-Hans": "已邀请",
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
    print(f"patched {len(ENTRIES)} Going Play keys")


if __name__ == "__main__":
    main()
