#!/usr/bin/env python3
"""Clarify Favorite Team vs My Teams copy + social My Teams default strings."""
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
    "profile_my_teams_subtitle": {
        "en": "Teams I'm part of",
        "es": "Equipos de los que formo parte",
        "fr": "Équipes dont je fais partie",
        "pt": "Equipes das quais faço parte",
        "de": "Teams, denen ich angehöre",
        "it": "Squadre di cui faccio parte",
        "pl": "Drużyny, do których należę",
        "ru": "Команды, в которых я состою",
        "sq": "Ekipet ku bëj pjesë",
        "zh-Hans": "我加入的队伍",
    },
    "profile_my_teams_a11y_section": {
        "en": "My Teams. Teams I'm part of. Separate from Favorite Team, your professional club.",
        "es": "Mis equipos. Equipos de los que formo parte. Distinto del Equipo favorito, tu club profesional.",
        "fr": "Mes équipes. Équipes dont je fais partie. Distinct de l’Équipe favorite, votre club professionnel.",
        "pt": "Minhas equipes. Equipes das quais faço parte. Separado da Equipe favorita, seu clube profissional.",
        "de": "Meine Teams. Teams, denen ich angehöre. Getrennt vom Lieblingsteam, deinem Profi-Club.",
        "it": "Le mie squadre. Squadre di cui faccio parte. Distinto dalla Squadra preferita, il tuo club professionistico.",
        "pl": "Moje drużyny. Drużyny, do których należę. Oddzielne od Ulubionej drużyny — klubu profesjonalnego.",
        "ru": "Мои команды. Команды, в которых я состою. Отдельно от Любимой команды — профессионального клуба.",
        "sq": "Ekipet e mia. Ekipet ku bëj pjesë. E ndarë nga Ekipi i preferuar, klubi juaj profesional.",
        "zh-Hans": "我的队伍。我加入的队伍。与收藏球队（职业俱乐部）不同。",
    },
    "profile_favorite_team_subtitle": {
        "en": "Your favorite professional sports team.",
        "es": "Tu equipo deportivo profesional favorito.",
        "fr": "Votre équipe sportive professionnelle favorite.",
        "pt": "Seu time esportivo profissional favorito.",
        "de": "Dein Lieblings-Profi-Sportteam.",
        "it": "La tua squadra sportiva professionistica preferita.",
        "pl": "Twoja ulubiona profesjonalna drużyna sportowa.",
        "ru": "Ваша любимая профессиональная спортивная команда.",
        "sq": "Ekipi juaj i preferuar profesional sportiv.",
        "zh-Hans": "你最喜欢的职业运动队。",
    },
    "profile_favorite_teams_subtitle": {
        "en": "Professional clubs you follow.",
        "es": "Clubes profesionales que sigues.",
        "fr": "Clubs professionnels que vous suivez.",
        "pt": "Clubes profissionais que você acompanha.",
        "de": "Profi-Clubs, denen du folgst.",
        "it": "Club professionistici che segui.",
        "pl": "Profesjonalne kluby, które obserwujesz.",
        "ru": "Профессиональные клубы, на которые вы подписаны.",
        "sq": "Klube profesionale që ndiqni.",
        "zh-Hans": "你关注的职业俱乐部。",
    },
    "profile_favorite_teams_subtitle_empty": {
        "en": "Add professional clubs you follow.",
        "es": "Añade clubes profesionales que sigues.",
        "fr": "Ajoutez des clubs professionnels que vous suivez.",
        "pt": "Adicione clubes profissionais que você acompanha.",
        "de": "Füge Profi-Clubs hinzu, denen du folgst.",
        "it": "Aggiungi club professionistici che segui.",
        "pl": "Dodaj profesjonalne kluby, które obserwujesz.",
        "ru": "Добавьте профессиональные клубы, на которые вы подписаны.",
        "sq": "Shto klube profesionale që ndiqni.",
        "zh-Hans": "添加你关注的职业俱乐部。",
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
