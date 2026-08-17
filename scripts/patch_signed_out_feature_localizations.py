#!/usr/bin/env python3
"""Localization for shared signed-out feature landings (Chat / Going / Sign In hint)."""
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
    "signed_out_sign_in_hint": {
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
    "chat_signed_out_title": {
        "en": "Sign in to chat",
        "es": "Inicia sesión para chatear",
        "fr": "Connectez-vous pour discuter",
        "pt": "Entre para conversar",
        "de": "Melde dich an, um zu chatten",
        "it": "Accedi per chattare",
        "nl": "Log in om te chatten",
        "pl": "Zaloguj się, aby czatować",
        "ru": "Войдите, чтобы переписываться",
        "sq": "Hyni për të biseduar",
        "zh-Hans": "登录以聊天",
    },
    "chat_signed_out_body": {
        "en": "Chat with friends, teammates, groups, and businesses in real time.",
        "es": "Chatea en tiempo real con amigos, compañeros, grupos y negocios.",
        "fr": "Discutez en temps réel avec vos amis, coéquipiers, groupes et entreprises.",
        "pt": "Converse em tempo real com amigos, colegas, grupos e empresas.",
        "de": "Chatte in Echtzeit mit Freunden, Teamkollegen, Gruppen und Unternehmen.",
        "it": "Chatta in tempo reale con amici, compagni, gruppi e attività.",
        "nl": "Chat in realtime met vrienden, teamgenoten, groepen en bedrijven.",
        "pl": "Czatuj w czasie rzeczywistym ze znajomymi, drużyną, grupami i firmami.",
        "ru": "Общайтесь в реальном времени с друзьями, командой, группами и компаниями.",
        "sq": "Bisedo në kohë reale me miq, shokë ekipi, grupe dhe biznese.",
        "zh-Hans": "与好友、队友、群组和商家实时聊天。",
    },
    "going_signed_out_title": {
        "en": "Sign in to save games",
        "es": "Inicia sesión para guardar partidos",
        "fr": "Connectez-vous pour enregistrer des matchs",
        "pt": "Entre para salvar jogos",
        "de": "Melde dich an, um Spiele zu speichern",
        "it": "Accedi per salvare le partite",
        "nl": "Log in om wedstrijden op te slaan",
        "pl": "Zaloguj się, aby zapisywać mecze",
        "ru": "Войдите, чтобы сохранять игры",
        "sq": "Hyni për të ruajtur ndeshjet",
        "zh-Hans": "登录以收藏比赛",
    },
    "going_signed_out_body": {
        "en": "Save your favorite games, receive live updates, and access them anytime.",
        "es": "Guarda tus partidos favoritos, recibe actualizaciones en vivo y accede a ellos cuando quieras.",
        "fr": "Enregistrez vos matchs favoris, recevez des mises à jour en direct et retrouvez-les à tout moment.",
        "pt": "Salve seus jogos favoritos, receba atualizações ao vivo e acesse-os quando quiser.",
        "de": "Speichere deine Lieblingsspiele, erhalte Live-Updates und greife jederzeit darauf zu.",
        "it": "Salva le partite preferite, ricevi aggiornamenti live e accedi in qualsiasi momento.",
        "nl": "Sla je favoriete wedstrijden op, ontvang live-updates en open ze wanneer je wilt.",
        "pl": "Zapisuj ulubione mecze, otrzymuj aktualizacje na żywo i wracaj do nich w każdej chwili.",
        "ru": "Сохраняйте любимые игры, получайте прямые обновления и открывайте их в любое время.",
        "sq": "Ruaj ndeshjet e tua të preferuara, merr përditësime live dhe hap i kur të duash.",
        "zh-Hans": "收藏你喜欢的比赛，接收实时更新，随时查看。",
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
