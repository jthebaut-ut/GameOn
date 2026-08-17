#!/usr/bin/env python3
"""Insert Going → Pro Games redesign localization keys without rewriting the catalog."""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
XCSTRINGS = ROOT / "GameOn" / "Localizable.xcstrings"

LANGS = ["de", "en", "es", "fr", "it", "nl", "pl", "pt", "ru", "sq", "zh-Hans"]

ENTRIES: dict[str, dict[str, str]] = {
    "going_pro_upcoming": {
        "en": "Upcoming Pro Games",
        "es": "Próximos Pro Games",
        "fr": "Pro Games à venir",
        "pt": "Próximos Pro Games",
        "de": "Kommende Pro Games",
        "it": "Pro Games in arrivo",
        "pl": "Nadchodzące Pro Games",
        "ru": "Ближайшие Pro Games",
        "sq": "Pro Games të ardhshme",
        "zh-Hans": "即将开始的职业赛事",
        "nl": "Aankomende Pro Games",
    },
    "going_pro_badge_favorite_team": {
        "en": "Favorite Team",
        "es": "Equipo favorito",
        "fr": "Équipe favorite",
        "pt": "Time favorito",
        "de": "Lieblingsteam",
        "it": "Squadra preferita",
        "pl": "Ulubiona drużyna",
        "ru": "Любимая команда",
        "sq": "Ekipi i preferuar",
        "zh-Hans": "收藏球队",
        "nl": "Favoriete team",
    },
    "going_pro_team_alerts_subtitle": {
        "en": "Kickoff, scores, and final alerts",
        "es": "Inicio, marcadores y alertas finales",
        "fr": "Coup d’envoi, scores et alertes finales",
        "pt": "Início, placares e alertas finais",
        "de": "Anpfiff, Ergebnisse und Final-Alerts",
        "it": "Calcio d’inizio, punteggi e avvisi finali",
        "pl": "Rozpoczęcie, wyniki i alerty końcowe",
        "ru": "Старты, счёт и финальные оповещения",
        "sq": "Fillimi, rezultatet dhe njoftimet finale",
        "zh-Hans": "开赛、比分与完场提醒",
        "nl": "Aftrap, scores en eindmeldingen",
    },
    "going_pro_empty_title": {
        "en": "No pro games yet",
        "es": "Aún no hay Pro Games",
        "fr": "Pas encore de Pro Games",
        "pt": "Ainda não há Pro Games",
        "de": "Noch keine Pro Games",
        "it": "Nessun Pro Game ancora",
        "pl": "Brak Pro Games",
        "ru": "Пока нет Pro Games",
        "sq": "Nuk ka Pro Games ende",
        "zh-Hans": "暂无职业赛事",
        "nl": "Nog geen Pro Games",
    },
    "going_pro_empty_supporting": {
        "en": "Save a game or add favorite teams to follow what matters to you.",
        "es": "Guarda un partido o añade equipos favoritos para seguir lo que te importa.",
        "fr": "Enregistrez un match ou ajoutez des équipes favorites pour suivre ce qui compte.",
        "pt": "Salve um jogo ou adicione times favoritos para acompanhar o que importa.",
        "de": "Speichere ein Spiel oder füge Lieblingsteams hinzu, um zu folgen, was dir wichtig ist.",
        "it": "Salva una partita o aggiungi squadre preferite per seguire ciò che conta.",
        "pl": "Zapisz mecz lub dodaj ulubione drużyny, aby śledzić to, co ważne.",
        "ru": "Сохраните игру или добавьте любимые команды, чтобы следить за важным.",
        "sq": "Ruani një ndeshje ose shtoni ekipe të preferuara për të ndjekur atë që ka rëndësi.",
        "zh-Hans": "收藏一场比赛或添加喜爱的球队，关注对你重要的赛事。",
        "nl": "Bewaar een wedstrijd of voeg favoriete teams toe om te volgen wat voor jou telt.",
    },
    "going_pro_explore": {
        "en": "Explore Pro Games",
        "es": "Explorar Pro Games",
        "fr": "Explorer les Pro Games",
        "pt": "Explorar Pro Games",
        "de": "Pro Games entdecken",
        "it": "Esplora Pro Games",
        "pl": "Przeglądaj Pro Games",
        "ru": "Смотреть Pro Games",
        "sq": "Eksploro Pro Games",
        "zh-Hans": "浏览职业赛事",
        "nl": "Ontdek Pro Games",
    },
    "going_pro_no_favorites": {
        "en": "No favorite teams yet.",
        "es": "Aún no hay equipos favoritos.",
        "fr": "Pas encore d’équipes favorites.",
        "pt": "Ainda não há times favoritos.",
        "de": "Noch keine Lieblingsteams.",
        "it": "Nessuna squadra preferita ancora.",
        "pl": "Nie masz jeszcze ulubionych drużyn.",
        "ru": "Пока нет любимых команд.",
        "sq": "Nuk ka ekipe të preferuara ende.",
        "zh-Hans": "暂无收藏球队。",
        "nl": "Nog geen favoriete teams.",
    },
    "going_pro_add_a11y": {
        "en": "Add favorite team, button",
        "es": "Añadir equipo favorito, botón",
        "fr": "Ajouter une équipe favorite, bouton",
        "pt": "Adicionar time favorito, botão",
        "de": "Lieblingsteam hinzufügen, Taste",
        "it": "Aggiungi squadra preferita, pulsante",
        "pl": "Dodaj ulubioną drużynę, przycisk",
        "ru": "Добавить любимую команду, кнопка",
        "sq": "Shto ekip të preferuar, buton",
        "zh-Hans": "添加收藏球队，按钮",
        "nl": "Favoriet team toevoegen, knop",
    },
    "going_pro_favorite_team_a11y_format": {
        "en": "%@, favorite team",
        "es": "%@, equipo favorito",
        "fr": "%@, équipe favorite",
        "pt": "%@, time favorito",
        "de": "%@, Lieblingsteam",
        "it": "%@, squadra preferita",
        "pl": "%@, ulubiona drużyna",
        "ru": "%@, любимая команда",
        "sq": "%@, ekipi i preferuar",
        "zh-Hans": "%@，收藏球队",
        "nl": "%@, favoriet team",
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
    print(f"inserted {inserted} Going Pro Games keys")


if __name__ == "__main__":
    main()
