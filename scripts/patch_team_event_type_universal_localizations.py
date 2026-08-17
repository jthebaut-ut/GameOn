#!/usr/bin/env python3
"""Localizations for universal Team Event Type taxonomy + event-oriented chrome."""
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
    "team_schedule_event_details": {
        "en": "Event Details",
        "es": "Detalles del evento",
        "fr": "Détails de l’événement",
        "pt": "Detalhes do evento",
        "de": "Eventdetails",
        "it": "Dettagli evento",
        "pl": "Szczegóły wydarzenia",
        "ru": "Детали события",
        "sq": "Detajet e eventit",
        "zh-Hans": "活动详情",
        "nl": "Evenementdetails",
    },
    "team_schedule_date_subtitle_event": {
        "en": "When is the event?",
        "es": "¿Cuándo es el evento?",
        "fr": "Quand a lieu l’événement ?",
        "pt": "Quando é o evento?",
        "de": "Wann ist das Event?",
        "it": "Quando è l’evento?",
        "pl": "Kiedy jest wydarzenie?",
        "ru": "Когда событие?",
        "sq": "Kur është eventi?",
        "zh-Hans": "活动何时举行？",
        "nl": "Wanneer is het evenement?",
    },
    "team_schedule_location_subtitle_event": {
        "en": "Where will it happen?",
        "es": "¿Dónde tendrá lugar?",
        "fr": "Où cela aura-t-il lieu ?",
        "pt": "Onde vai acontecer?",
        "de": "Wo findet es statt?",
        "it": "Dove si svolge?",
        "pl": "Gdzie się odbędzie?",
        "ru": "Где это пройдёт?",
        "sq": "Ku do të ndodhë?",
        "zh-Hans": "在哪里举行？",
        "nl": "Waar vindt het plaats?",
    },
    "team_event_type_game_match": {
        "en": "Game / Match",
        "es": "Partido / Match",
        "fr": "Match / Rencontre",
        "pt": "Jogo / Partida",
        "de": "Spiel / Match",
        "it": "Partita / Match",
        "pl": "Mecz / Spotkanie",
        "ru": "Игра / Матч",
        "sq": "Lojë / Ndeshje",
        "zh-Hans": "比赛 / 对阵",
        "nl": "Wedstrijd / Match",
    },
    "team_event_type_tournament_competition": {
        "en": "Tournament / Competition",
        "es": "Torneo / Competición",
        "fr": "Tournoi / Compétition",
        "pt": "Torneio / Competição",
        "de": "Turnier / Wettbewerb",
        "it": "Torneo / Competizione",
        "pl": "Turniej / Zawody",
        "ru": "Турнир / Соревнование",
        "sq": "Turne / Kompeticion",
        "zh-Hans": "锦标赛 / 竞赛",
        "nl": "Toernooi / wedstrijd",
    },
    "team_event_type_clinic_camp": {
        "en": "Clinic / Camp",
        "es": "Clínica / Campamento",
        "fr": "Clinique / Camp",
        "pt": "Clínica / Acampamento",
        "de": "Clinic / Camp",
        "it": "Clinic / Camp",
        "pl": "Klinik / Obóz",
        "ru": "Клиника / Лагерь",
        "sq": "Klinikë / Kamp",
        "zh-Hans": "训练营 / 营地",
        "nl": "Clinic / kamp",
    },
    "team_event_type_training_workout": {
        "en": "Training / Workout",
        "es": "Entrenamiento / Workout",
        "fr": "Entraînement / Workout",
        "pt": "Treino / Workout",
        "de": "Training / Workout",
        "it": "Allenamento / Workout",
        "pl": "Trening / Workout",
        "ru": "Тренировка / Workout",
        "sq": "Stërvitje / Workout",
        "zh-Hans": "训练 / 锻炼",
        "nl": "Training / Workout",
    },
    "team_event_type_group_activity_session": {
        "en": "Group Activity / Session",
        "es": "Actividad / sesión en grupo",
        "fr": "Activité / session de groupe",
        "pt": "Atividade / sessão em grupo",
        "de": "Gruppenaktivität / Session",
        "it": "Attività / sessione di gruppo",
        "pl": "Aktywność / sesja grupowa",
        "ru": "Групповая активность / сессия",
        "sq": "Aktivitet / sesion në grup",
        "zh-Hans": "团体活动 / 场次",
        "nl": "Groepsactiviteit / sessie",
    },
    "team_event_type_race_meet": {
        "en": "Race / Meet",
        "es": "Carrera / Meet",
        "fr": "Course / Meeting",
        "pt": "Corrida / Meet",
        "de": "Rennen / Meeting",
        "it": "Gara / Meeting",
        "pl": "Wyścig / Meet",
        "ru": "Гонка / соревнование",
        "sq": "Gara / Meet",
        "zh-Hans": "赛事 / 运动会",
        "nl": "Race / Meet",
    },
    "team_event_type_race_competition": {
        "en": "Race / Competition",
        "es": "Carrera / Competición",
        "fr": "Course / Compétition",
        "pt": "Corrida / Competição",
        "de": "Rennen / Wettbewerb",
        "it": "Gara / Competizione",
        "pl": "Wyścig / Zawody",
        "ru": "Гонка / соревнование",
        "sq": "Gara / Kompeticion",
        "zh-Hans": "赛事 / 竞赛",
        "nl": "Race / wedstrijd",
    },
    "team_event_type_competition": {
        "en": "Competition",
        "es": "Competición",
        "fr": "Compétition",
        "pt": "Competição",
        "de": "Wettbewerb",
        "it": "Competizione",
        "pl": "Zawody",
        "ru": "Соревнование",
        "sq": "Kompeticion",
        "zh-Hans": "竞赛",
        "nl": "Wedstrijd",
    },
    "team_event_type_practice_training": {
        "en": "Practice / Training",
        "es": "Práctica / Entrenamiento",
        "fr": "Entraînement / Pratique",
        "pt": "Prática / Treino",
        "de": "Übung / Training",
        "it": "Pratica / Allenamento",
        "pl": "Ćwiczenia / Trening",
        "ru": "Практика / Тренировка",
        "sq": "Praktikë / Stërvitje",
        "zh-Hans": "练习 / 训练",
        "nl": "Oefening / training",
    },
    "team_event_type_group_session": {
        "en": "Group Session / Activity",
        "es": "Sesión / actividad en grupo",
        "fr": "Session / activité de groupe",
        "pt": "Sessão / atividade em grupo",
        "de": "Gruppensession / Aktivität",
        "it": "Sessione / attività di gruppo",
        "pl": "Sesja / aktywność grupowa",
        "ru": "Групповая сессия / активность",
        "sq": "Sesion / aktivitet në grup",
        "zh-Hans": "团体场次 / 活动",
        "nl": "Groepssessie / activiteit",
    },
    "team_event_type_training": {
        "en": "Training",
        "es": "Entrenamiento",
        "fr": "Entraînement",
        "pt": "Treino",
        "de": "Training",
        "it": "Allenamento",
        "pl": "Trening",
        "ru": "Тренировка",
        "sq": "Stërvitje",
        "zh-Hans": "训练",
        "nl": "Training",
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
