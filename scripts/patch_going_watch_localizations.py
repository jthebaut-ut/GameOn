#!/usr/bin/env python3
"""Insert Going → Watch redesign localization keys without rewriting the catalog."""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
XCSTRINGS = ROOT / "GameOn" / "Localizable.xcstrings"

LANGS = ["de", "en", "es", "fr", "it", "nl", "pl", "pt", "ru", "sq", "zh-Hans"]

ENTRIES: dict[str, dict[str, str]] = {
    "going_watch_empty_title": {
        "en": "Nothing planned yet",
        "es": "Aún no hay planes",
        "fr": "Rien de prévu pour le moment",
        "pt": "Nada planejado ainda",
        "de": "Noch nichts geplant",
        "it": "Niente in programma",
        "pl": "Nic jeszcze nie zaplanowano",
        "ru": "Пока ничего не запланировано",
        "sq": "Asgjë e planifikuar ende",
        "zh-Hans": "暂无安排",
        "nl": "Nog niets gepland",
    },
    "going_watch_empty_supporting": {
        "en": "Discover games or save your favorite watch spots.",
        "es": "Descubre partidos o guarda tus watch spots favoritos.",
        "fr": "Découvrez des matchs ou enregistrez vos watch spots favoris.",
        "pt": "Descubra jogos ou salve seus watch spots favoritos.",
        "de": "Entdecke Spiele oder speichere deine Lieblings-Watch-Spots.",
        "it": "Scopri partite o salva i tuoi watch spot preferiti.",
        "pl": "Odkrywaj mecze lub zapisz ulubione miejsca do oglądania.",
        "ru": "Находите игры или сохраняйте любимые watch spots.",
        "sq": "Zbuloni ndeshje ose ruani watch spots tuaja të preferuara.",
        "zh-Hans": "发现赛事或收藏你喜爱的观赛地点。",
        "nl": "Ontdek wedstrijden of bewaar je favoriete watch spots.",
    },
    "going_watch_empty_games": {
        "en": "No games you're going to yet.",
        "es": "Aún no hay partidos a los que vayas.",
        "fr": "Aucun match auquel vous allez pour le moment.",
        "pt": "Ainda não há jogos que você vai assistir.",
        "de": "Noch keine Spiele, zu denen du gehst.",
        "it": "Nessuna partita a cui vai ancora.",
        "pl": "Nie masz jeszcze meczów, na które idziesz.",
        "ru": "Пока нет игр, на которые вы идёте.",
        "sq": "Nuk keni ndeshje ku po shkoni ende.",
        "zh-Hans": "还没有你要去看的比赛。",
        "nl": "Nog geen wedstrijden waar je naartoe gaat.",
    },
    "going_watch_empty_games_supporting": {
        "en": "Discover games being hosted near you.",
        "es": "Descubre partidos cerca de ti.",
        "fr": "Découvrez des matchs près de chez vous.",
        "pt": "Descubra jogos perto de você.",
        "de": "Entdecke Spiele in deiner Nähe.",
        "it": "Scopri partite vicino a te.",
        "pl": "Odkrywaj mecze w Twojej okolicy.",
        "ru": "Находите игры рядом с вами.",
        "sq": "Zbuloni ndeshje pranë jush.",
        "zh-Hans": "发现附近正在举办的赛事。",
        "nl": "Ontdek wedstrijden bij jou in de buurt.",
    },
    "going_watch_empty_spots": {
        "en": "No favorite watch spots yet.",
        "es": "Aún no hay watch spots favoritos.",
        "fr": "Pas encore de watch spots favoris.",
        "pt": "Ainda não há watch spots favoritos.",
        "de": "Noch keine Lieblings-Watch-Spots.",
        "it": "Nessun watch spot preferito ancora.",
        "pl": "Nie masz jeszcze ulubionych miejsc do oglądania.",
        "ru": "Пока нет любимых watch spots.",
        "sq": "Nuk keni watch spots të preferuara ende.",
        "zh-Hans": "还没有收藏的观赛地点。",
        "nl": "Nog geen favoriete watch spots.",
    },
    "going_watch_empty_spots_supporting": {
        "en": "Save a watch spot from Discover.",
        "es": "Guarda un watch spot desde Discover.",
        "fr": "Enregistrez un watch spot depuis Discover.",
        "pt": "Salve um watch spot em Discover.",
        "de": "Speichere einen Watch Spot in Discover.",
        "it": "Salva un watch spot da Discover.",
        "pl": "Zapisz miejsce do oglądania w Discover.",
        "ru": "Сохраните watch spot в Discover.",
        "sq": "Ruani një watch spot nga Discover.",
        "zh-Hans": "在 Discover 中收藏观赛地点。",
        "nl": "Bewaar een watch spot via Discover.",
    },
    "going_watch_tonight": {
        "en": "Tonight",
        "es": "Esta noche",
        "fr": "Ce soir",
        "pt": "Esta noite",
        "de": "Heute Abend",
        "it": "Stasera",
        "pl": "Dziś wieczorem",
        "ru": "Сегодня вечером",
        "sq": "Sot në mbrëmje",
        "zh-Hans": "今晚",
        "nl": "Vanavond",
    },
}


def unit_block(translations: dict[str, str]) -> str:
    parts = []
    for lang in LANGS:
        value = translations.get(lang, translations["en"])
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        parts.append(
            f'''        "{lang}": {{
          "stringUnit": {{
            "state": "translated",
            "value": "{escaped}"
          }}
        }}'''
        )
    return ",\n".join(parts)


def entry_block(key: str, translations: dict[str, str]) -> str:
    return f'''    "{key}": {{
      "extractionState": "manual",
      "localizations": {{
{unit_block(translations)}
      }}
    }},
'''


def main() -> None:
    text = XCSTRINGS.read_text(encoding="utf-8")
    needle = '    "going_pro_sports_subtitle": {'
    if needle not in text:
        raise SystemExit("needle going_pro_sports_subtitle not found")
    inserted = 0
    block = ""
    for key, translations in ENTRIES.items():
        if f'"{key}"' in text:
            print(f"skip {key}")
            continue
        block += entry_block(key, translations)
        inserted += 1
    if inserted == 0:
        print("all keys present")
        return
    text = text.replace(needle, block + needle, 1)
    XCSTRINGS.write_text(text, encoding="utf-8")
    print(f"inserted {inserted} Going Watch keys")


if __name__ == "__main__":
    main()
