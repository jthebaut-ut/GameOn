#!/usr/bin/env python3
"""Add localization keys clarifying FanGeo My Teams vs hero Favorite Team."""
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
    "profile_my_teams_section": {
        "en": "My Teams on Profile",
        "es": "Mis equipos en el perfil",
        "fr": "Mes équipes sur le profil",
        "pt": "Minhas equipes no perfil",
        "de": "Meine Teams im Profil",
        "it": "Le mie squadre nel profilo",
        "pl": "Moje drużyny w profilu",
        "ru": "Мои команды в профиле",
        "sq": "Ekipet e mia në profil",
        "zh-Hans": "个人资料中的我的队伍",
    },
    "profile_my_teams_a11y_section": {
        "en": "My Teams. Teams I'm part of. Separate from Favorite Team, your professional club.",
        "es": "Mis equipos. Equipos FanGeo de los que eres miembro. Distinto del Equipo favorito, tu club profesional.",
        "fr": "Mes équipes. Équipes FanGeo dont vous êtes membre. Distinct de l’Équipe favorite, votre club professionnel.",
        "pt": "Minhas equipes. Equipes FanGeo das quais você é membro. Separado da Equipe favorita, seu clube profissional.",
        "de": "Meine Teams. FanGeo-Teams, denen du angehörst. Getrennt vom Lieblingsteam, deinem Profi-Club.",
        "it": "Le mie squadre. Squadre FanGeo di cui sei membro. Distinto dalla Squadra preferita, il tuo club professionistico.",
        "pl": "Moje drużyny. Drużyny FanGeo, do których należysz. Oddzielne od Ulubionej drużyny — klubu profesjonalnego.",
        "ru": "Мои команды. Команды FanGeo, в которых вы состоите. Отдельно от Любимой команды — профессионального клуба.",
        "sq": "Ekipet e mia. Ekipe FanGeo ku jeni anëtar. E ndarë nga Ekipi i preferuar, klubi juaj profesional.",
        "zh-Hans": "我的队伍。你加入的 FanGeo 队伍。与收藏球队（职业俱乐部）不同。",
    },
}


def main() -> None:
    data = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    strings = data.setdefault("strings", {})
    for key, translations in ENTRIES.items():
        entry = strings.get(key, {"extractionState": "manual", "localizations": {}})
        entry["extractionState"] = "manual"
        locs_map = entry.setdefault("localizations", {})
        for lang, payload in locs(translations).items():
            locs_map[lang] = payload
        strings[key] = entry
    XCSTRINGS.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Patched {len(ENTRIES)} keys into {XCSTRINGS}")


if __name__ == "__main__":
    main()
