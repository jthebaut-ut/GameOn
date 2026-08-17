#!/usr/bin/env python3
"""Restore missing/broken startup-guide keys. Does not overwrite good translations.

Source of intended copy:
- Agent transcript 38b71419 (Schedule & Live + Teams insert, later lost in catalog truncate)
- Agent transcript b6a4d907 (profile demo fallback artwork + onboarding a11y)
- Existing catalog values for nl fills of keys that already have 10 locales
"""
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
XCSTRINGS = ROOT / "GameOn" / "Localizable.xcstrings"
LANGS = ["en", "es", "fr", "pt", "de", "it", "pl", "ru", "sq", "zh-Hans", "nl"]


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def tr(en: str, es: str, fr: str, pt: str, de: str, it: str, pl: str, ru: str, sq: str, zh: str, nl: str) -> dict[str, str]:
    return {
        "en": en,
        "es": es,
        "fr": fr,
        "pt": pt,
        "de": de,
        "it": it,
        "pl": pl,
        "ru": ru,
        "sq": sq,
        "zh-Hans": zh,
        "nl": nl,
    }


# Completely missing from Localizable.xcstrings (screenshot failures).
ENTRIES: dict[str, dict[str, str]] = {
    "guide_schedule_live_title": tr(
        "Schedule & Live",
        "Calendario y En vivo",
        "Calendrier & Live",
        "Agenda e Ao vivo",
        "Zeitplan & Live",
        "Calendario e Live",
        "Harmonogram i Na żywo",
        "Расписание и Live",
        "Orari & Live",
        "赛程与直播",
        "Agenda & Live",
    ),
    "guide_schedule_live_primary": tr(
        "Stay On Top of Every Game",
        "Mantente al día con cada partido",
        "Reste au top de chaque match",
        "Fique por dentro de cada jogo",
        "Behalte jedes Spiel im Blick",
        "Resta aggiornato su ogni partita",
        "Bądź na bieżąco z każdym meczem",
        "Будь в курсе каждой игры",
        "Qëndro në krye të çdo ndeshjeje",
        "掌握每一场比赛",
        "Blijf bij elke wedstrijd",
    ),
    "guide_schedule_live_bullet_1": tr(
        "Follow live games and scores",
        "Sigue partidos y marcadores en vivo",
        "Suis les matchs et scores en direct",
        "Acompanhe jogos e placares ao vivo",
        "Live-Spiele und Scores verfolgen",
        "Segui partite e score live",
        "Śledź mecze i wyniki na żywo",
        "Следи за матчами и счётом в прямом эфире",
        "Ndiq ndeshjet dhe rezultatet live",
        "关注直播比赛与比分",
        "Volg live wedstrijden en scores",
    ),
    "guide_schedule_live_bullet_2": tr(
        "Plan watch parties and games",
        "Planifica watch parties y partidos",
        "Planifie watch parties et matchs",
        "Planeje watch parties e jogos",
        "Watchpartys und Spiele planen",
        "Pianifica watch party e partite",
        "Planuj watch party i mecze",
        "Планируй вотч-пати и игры",
        "Planifiko watch party dhe ndeshje",
        "规划观赛派对与比赛",
        "Plan watchparty’s en wedstrijden",
    ),
    "guide_schedule_live_bullet_3": tr(
        "Find pickup and Team events",
        "Encuentra pickup y eventos de Team",
        "Trouve pickups et événements d’équipe",
        "Encontre pickup e eventos de Team",
        "Pickup- und Team-Events finden",
        "Trova pickup ed eventi Team",
        "Znajdź pickup i wydarzenia Team",
        "Находи пикапы и события Teams",
        "Gjej pickup dhe evente Team",
        "发现约球与队伍活动",
        "Vind pickup- en Teamevents",
    ),
    "guide_schedule_live_bullet_4": tr(
        "Follow your favorite pro teams",
        "Sigue tus equipos profesionales favoritos",
        "Suis tes équipes pro préférées",
        "Siga seus times profissionais favoritos",
        "Folge deinen Lieblings-Profi-Teams",
        "Segui le tue squadre pro preferite",
        "Śledź ulubione drużyny pro",
        "Следи за любимыми про-командами",
        "Ndiq ekipet e tua të preferuara pro",
        "关注你喜爱的职业球队",
        "Volg je favoriete pro-teams",
    ),
    "guide_teams_primary": tr(
        "Play Together. Stay Connected.",
        "Jueguen juntos. Manténganse conectados.",
        "Jouez ensemble. Restez connectés.",
        "Joguem juntos. Fiquem conectados.",
        "Zusammen spielen. Verbunden bleiben.",
        "Giocate insieme. Restate connessi.",
        "Grajcie razem. Bądźcie w kontakcie.",
        "Играйте вместе. Оставайтесь на связи.",
        "Luani së bashku. Qëndroni të lidhur.",
        "一起比赛，保持联系。",
        "Samen spelen. Verbonden blijven.",
    ),
    "guide_teams_bullet_1": tr(
        "Create or join a team",
        "Crea o únete a un team",
        "Crée ou rejoins une équipe",
        "Crie ou entre num team",
        "Team erstellen oder beitreten",
        "Crea o unisciti a un team",
        "Utwórz lub dołącz do drużyny",
        "Создай команду или вступи в неё",
        "Krijo ose bashkohu në një ekip",
        "创建或加入队伍",
        "Maak of word lid van een team",
    ),
    "guide_teams_bullet_2": tr(
        "Team Chat, schedule, and roster",
        "Team Chat, calendario y roster",
        "Team Chat, calendrier et effectif",
        "Team Chat, agenda e plantel",
        "Team-Chat, Zeitplan und Kader",
        "Team Chat, calendario e roster",
        "Team Chat, harmonogram i skład",
        "Team Chat, расписание и состав",
        "Team Chat, orar dhe roster",
        "队伍聊天、赛程与名单",
        "Teamchat, schema en selectie",
    ),
    "guide_teams_bullet_3": tr(
        "RSVP and manage game-day plans",
        "Confirma asistencia y gestiona el día del partido",
        "RSVP et gère le jour de match",
        "RSVP e gerencie o dia de jogo",
        "RSVP und Spieltag-Pläne verwalten",
        "RSVP e gestisci il giorno gara",
        "RSVP i zarządzaj planami na mecz",
        "RSVP и планы на игровой день",
        "RSVP dhe menaxho planet e ndeshjes",
        "回复出席并管理比赛日计划",
        "RSVP en beheer wedstrijddagplannen",
    ),
    "guide_teams_bullet_4": tr(
        "Add players you manage",
        "Añade jugadores que gestionas",
        "Ajoute des joueurs que tu gères",
        "Adicione jogadores que você gerencia",
        "Spieler hinzufügen, die du verwaltest",
        "Aggiungi i giocatori che gestisci",
        "Dodaj zawodników, którymi zarządzasz",
        "Добавляй игроков, которыми управляешь",
        "Shto lojtarët që menaxhon",
        "添加你管理的球员",
        "Voeg spelers toe die je beheert",
    ),
    # Canonical Teams tab/guide title. Call site is titleKey: "teams".
    "teams": tr(
        "Teams",
        "Equipos",
        "Équipes",
        "Equipes",
        "Teams",
        "Squadre",
        "Drużyny",
        "Команды",
        "Ekipe",
        "队伍",
        "Teams",
    ),
}

# Existing English is an auto-extracted stub ("Guide profile demo …"). Restore intended copy.
OVERWRITE_STUB_KEYS: dict[str, dict[str, str]] = {
    "guide_profile_demo_badge": tr(
        "Rookie", "Novato", "Débutant", "Iniciante", "Neuling", "Principiante",
        "Początkujący", "Новичок", "Fillestar", "新手", "Rookie",
    ),
    "guide_profile_demo_name": tr(
        "Alex Morgan", "Alex Morgan", "Alex Morgan", "Alex Morgan", "Alex Morgan", "Alex Morgan",
        "Alex Morgan", "Alex Morgan", "Alex Morgan", "Alex Morgan", "Alex Morgan",
    ),
    "guide_profile_demo_handle": tr(
        "@alexmorgan", "@alexmorgan", "@alexmorgan", "@alexmorgan", "@alexmorgan", "@alexmorgan",
        "@alexmorgan", "@alexmorgan", "@alexmorgan", "@alexmorgan", "@alexmorgan",
    ),
    "guide_profile_demo_subtitle": tr(
        "Lakers fan in Salt Lake City",
        "Fan de los Lakers en Salt Lake City",
        "Fan des Lakers à Salt Lake City",
        "Fã dos Lakers em Salt Lake City",
        "Lakers-Fan in Salt Lake City",
        "Tifoso dei Lakers a Salt Lake City",
        "Fan Lakers w Salt Lake City",
        "Фанат Lakers в Солт-Лейк-Сити",
        "Tifoz i Lakers në Salt Lake City",
        "盐湖城的湖人球迷",
        "Lakers-fan in Salt Lake City",
    ),
    "guide_profile_demo_xp": tr(
        "128 XP", "128 XP", "128 XP", "128 XP", "128 XP", "128 XP",
        "128 XP", "128 XP", "128 XP", "128 XP", "128 XP",
    ),
    "guide_profile_demo_teams_metric": tr(
        "3 Teams", "3 equipos", "3 équipes", "3 times", "3 Teams", "3 squadre",
        "3 drużyny", "3 команды", "3 ekipe", "3 支球队", "3 teams",
    ),
    "guide_profile_demo_primary_team": tr(
        "Primary: Lakers",
        "Principal: Lakers",
        "Principale : Lakers",
        "Principal: Lakers",
        "Primär: Lakers",
        "Principale: Lakers",
        "Główna: Lakers",
        "Основная: Lakers",
        "Kryesore: Lakers",
        "主队：湖人",
        "Primair: Lakers",
    ),
    "guide_profile_demo_reputation": tr(
        "Reputation", "Reputación", "Réputation", "Reputação", "Ruf", "Reputazione",
        "Reputacja", "Репутация", "Reputacioni", "声誉", "Reputatie",
    ),
    "guide_profile_demo_trusted_fan": tr(
        "Trusted fan",
        "Fan de confianza",
        "Fan de confiance",
        "Fã confiável",
        "Vertrauenswürdiger Fan",
        "Fan affidabile",
        "Zaufany fan",
        "Надёжный фанат",
        "Tifoz i besueshëm",
        "可信粉丝",
        "Betrouwbare fan",
    ),
    "guide_profile_demo_fan_1_name": tr(
        "Jordan", "Jordan", "Jordan", "Jordan", "Jordan", "Jordan",
        "Jordan", "Jordan", "Jordan", "Jordan", "Jordan",
    ),
    "guide_profile_demo_fan_1_detail": tr(
        "Lakers fan",
        "Fan de los Lakers",
        "Fan des Lakers",
        "Fã dos Lakers",
        "Lakers-Fan",
        "Tifoso dei Lakers",
        "Fan Lakers",
        "Фанат Lakers",
        "Tifoz i Lakers",
        "湖人球迷",
        "Lakers-fan",
    ),
    "guide_profile_demo_fan_2_name": tr(
        "Mia", "Mia", "Mia", "Mia", "Mia", "Mia",
        "Mia", "Mia", "Mia", "Mia", "Mia",
    ),
    "guide_profile_demo_fan_2_detail": tr(
        "Jazz fan",
        "Fan de los Jazz",
        "Fan des Jazz",
        "Fã do Jazz",
        "Jazz-Fan",
        "Tifoso degli Jazz",
        "Fan Jazz",
        "Фанат Jazz",
        "Tifoz i Jazz",
        "爵士球迷",
        "Jazz-fan",
    ),
}

# Catalog currently stores the English source string in every locale.
A11Y_OVERWRITE_NON_EN: dict[str, dict[str, str]] = {
    "FanGeo onboarding": tr(
        "FanGeo onboarding",
        "Introducción a FanGeo",
        "Présentation FanGeo",
        "Introdução ao FanGeo",
        "FanGeo-Einführung",
        "Introduzione a FanGeo",
        "Wprowadzenie do FanGeo",
        "Знакомство с FanGeo",
        "Hyrja në FanGeo",
        "FanGeo 新手引导",
        "FanGeo-introductie",
    ),
    "Opens a fullscreen zoomable view of the onboarding illustration": tr(
        "Opens a fullscreen zoomable view of the onboarding illustration",
        "Abre una vista a pantalla completa con zoom de la ilustración de la guía",
        "Ouvre une vue plein écran zoomable de l’illustration du guide",
        "Abre uma visualização em tela cheia com zoom da ilustração do guia",
        "Öffnet eine Vollbildansicht mit Zoom der Onboarding-Illustration",
        "Apre una visualizzazione a schermo intero con zoom dell’illustrazione della guida",
        "Otwiera pełnoekranowy podgląd ilustracji przewodnika z możliwością powiększania",
        "Открывает полноэкранный просмотр иллюстрации гида с масштабированием",
        "Hap një pamje me ekran të plotë me zmadhim të ilustrimit të udhëzuesit",
        "打开可缩放的全屏欢迎插图",
        "Opent een zoombaar volledig scherm van de onboardingillustratie",
    ),
}

# Existing keys missing Dutch only. Do not clobber other locales.
NL_FILL: dict[str, str] = {
    "guide_chat_bullet_1": "Privéchats in de app",
    "guide_chat_bullet_2": "Plan watchparty’s",
    "guide_chat_bullet_3": "Coördineer pickupwedstrijden",
    "guide_chat_hero_a11y": "Chatillustratie van fans die een watchparty plannen",
    "guide_chat_primary": "Overleg met fans zonder je telefoonnummer te delen.",
    "guide_close_hint": "Sluit de onboardinggids",
    "guide_discover_bullet_1": "Vind sportsbars met live wedstrijden",
    "guide_discover_bullet_2": "Ontdek watchparty’s en venue-events",
    "guide_discover_bullet_3": "Doe mee aan pickupwedstrijden bij jou in de buurt",
    "guide_discover_hero_a11y": "Discover-kaartillustratie met sportsbars, venuewedstrijden, pickupplekken en pickupwedstrijden",
    "guide_discover_primary": "Ontdek wat er om je heen gebeurt",
    "guide_hide_at_startup_hint": "Als dit is geselecteerd, opent de gids niet automatisch bij het starten van de app",
    "guide_next": "Volgende",
    "guide_next_hint": "Toont de volgende onboardingpagina",
    "guide_page_of_format": "Pagina %1$lld van %2$lld",
    "guide_profile_bullet_1": "Voeg je favoriete teams toe",
    "guide_profile_bullet_2": "Personaliseer je fanprofiel",
    "guide_profile_bullet_3": "Ontdek fans met dezelfde interesses",
    "guide_profile_callout_reputation": "Reputatie & fanidentiteit",
    "guide_profile_hero_a11y": "FanGeo-profielscherm met favoriete teams, voorgestelde fans en fanidentiteit",
    "guide_profile_primary": "Bouw je fanidentiteit op",
    "guide_start_exploring": "Begin met ontdekken",
    "guide_welcome_body": "FanGeo is de all-in-one sportcommunity waar fans sportsbars, watchparty’s, pickupwedstrijden, livescores en lokale sportgroepen ontdekken.",
    "guide_welcome_bullet_1": "Vind sportsbars met live wedstrijden",
    "guide_welcome_bullet_2": "Ontdek watchparty’s bij jou in de buurt",
    "guide_welcome_bullet_3": "Doe mee aan pickupwedstrijden en lokale sportgroepen",
    "guide_welcome_hero_a11y": "Welkomstbanner van de FanGeo-sportcommunity",
    "guide_welcome_quick_tour": "Een korte rondleiding door FanGeo",
    "guide_welcome_tagline": "Vind wedstrijden. Vind mensen. Wees erbij.",
    "guide_welcome_title": "Welkom bij FanGeo",
    "welcome_guide_personalized_greeting_format": "Welkom, %@!",
}


def upsert(strings: dict, key: str, translations: dict[str, str], *, overwrite_empty_only: bool) -> None:
    entry = strings.get(key, {"extractionState": "manual", "localizations": {}})
    entry["extractionState"] = "manual"
    locs = entry.setdefault("localizations", {})
    for lang in LANGS:
        value = translations.get(lang)
        if not value:
            continue
        existing = (locs.get(lang) or {}).get("stringUnit", {}).get("value")
        if existing and overwrite_empty_only:
            continue
        locs[lang] = unit(value)
    strings[key] = entry


def upsert_non_en_if_equals_en(strings: dict, key: str, translations: dict[str, str]) -> None:
    entry = strings.get(key, {"extractionState": "manual", "localizations": {}})
    entry["extractionState"] = "manual"
    locs = entry.setdefault("localizations", {})
    en_value = translations["en"]
    if not (locs.get("en") or {}).get("stringUnit", {}).get("value"):
        locs["en"] = unit(en_value)
    for lang in LANGS:
        if lang == "en":
            continue
        value = translations.get(lang)
        if not value:
            continue
        existing = (locs.get(lang) or {}).get("stringUnit", {}).get("value")
        if existing and existing != en_value and existing != key:
            continue
        locs[lang] = unit(value)
    strings[key] = entry


def main() -> None:
    data = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    strings = data.setdefault("strings", {})
    inserted = 0
    overwritten = 0
    filled = 0

    for key, translations in ENTRIES.items():
        missing = [lang for lang in LANGS if lang not in translations]
        if missing:
            raise SystemExit(f"{key} missing languages: {missing}")
        existed = bool(
            ((strings.get(key) or {}).get("localizations") or {}).get("en", {}).get("stringUnit", {}).get("value")
        )
        upsert(strings, key, translations, overwrite_empty_only=True)
        if not existed:
            inserted += 1

    for key, translations in OVERWRITE_STUB_KEYS.items():
        upsert(strings, key, translations, overwrite_empty_only=False)
        overwritten += 1

    for key, translations in A11Y_OVERWRITE_NON_EN.items():
        upsert_non_en_if_equals_en(strings, key, translations)
        overwritten += 1

    for key, nl_value in NL_FILL.items():
        entry = strings.get(key)
        if not entry:
            continue
        locs = entry.setdefault("localizations", {})
        existing = (locs.get("nl") or {}).get("stringUnit", {}).get("value")
        if not existing:
            locs["nl"] = unit(nl_value)
            filled += 1

    XCSTRINGS.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(
        f"startup guide: inserted={inserted} overwritten_stubs={overwritten} "
        f"nl_fills={filled} catalog_keys={len(strings)}"
    )


if __name__ == "__main__":
    main()
