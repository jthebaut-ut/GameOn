#!/usr/bin/env python3
"""Localization for the signed-out Teams landing state."""
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
    "teams_signed_out_title": {
        "en": "Sign in to access your teams",
        "es": "Inicia sesión para acceder a tus equipos",
        "fr": "Connectez-vous pour accéder à vos équipes",
        "pt": "Entre para acessar seus times",
        "de": "Melde dich an, um auf deine Teams zuzugreifen",
        "it": "Accedi per vedere i tuoi team",
        "pl": "Zaloguj się, aby uzyskać dostęp do swoich zespołów",
        "ru": "Войдите, чтобы открыть свои команды",
        "sq": "Hyni për të hyrë te ekipet tuaja",
        "zh-Hans": "登录以访问你的队伍",
        "nl": "Log in om je teams te bekijken",
    },
    "teams_signed_out_body": {
        "en": "View your teams, schedules, chats, rosters, invitations, and player activity.",
        "es": "Consulta tus equipos, calendarios, chats, plantillas, invitaciones y la actividad de los jugadores.",
        "fr": "Consultez vos équipes, calendriers, discussions, effectifs, invitations et l’activité des joueurs.",
        "pt": "Veja seus times, agendas, chats, elencos, convites e a atividade dos jogadores.",
        "de": "Sieh deine Teams, Spielpläne, Chats, Kader, Einladungen und Spieleraktivität.",
        "it": "Consulta team, calendari, chat, rose, inviti e attività dei giocatori.",
        "pl": "Przeglądaj zespoły, harmonogramy, czaty, składy, zaproszenia i aktywność zawodników.",
        "ru": "Смотрите команды, расписания, чаты, составы, приглашения и активность игроков.",
        "sq": "Shiko ekipet, oraret, bisedat, listat, ftesat dhe aktivitetin e lojtarëve.",
        "zh-Hans": "查看你的队伍、赛程、聊天、名单、邀请和球员动态。",
        "nl": "Bekijk je teams, schema’s, chats, selecties, uitnodigingen en speleractiviteit.",
    },
    "teams_signed_out_sign_in_hint": {
        "en": "Opens Sign In",
        "es": "Abre Iniciar sesión",
        "fr": "Ouvre Se connecter",
        "pt": "Abre Entrar",
        "de": "Öffnet Anmelden",
        "it": "Apre Accedi",
        "nl": "Opent Inloggen",
        "pl": "Otwiera logowanie",
        "ru": "Открывает вход",
        "sq": "Hap Hyni",
        "zh-Hans": "打开登录",
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
