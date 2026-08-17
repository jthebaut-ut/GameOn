#!/usr/bin/env python3
"""Localization for Fans Live Now open-chat / view-profile actions."""
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
XCSTRINGS = ROOT / "GameOn" / "Localizable.xcstrings"
SUPPORTED = ["en", "es", "fr", "pt", "de", "it", "pl", "ru", "sq", "zh-Hans", "nl"]


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def locs(translations: dict[str, str]) -> dict:
    return {lang: unit(translations.get(lang, translations["en"])) for lang in SUPPORTED}


ENTRIES: dict[str, dict[str, str]] = {
    "chat_fans_live_now_open_chat_a11y_hint": {
        "en": "Opens a message conversation",
        "es": "Abre una conversación de mensajes",
        "fr": "Ouvre une conversation",
        "pt": "Abre uma conversa de mensagens",
        "de": "Öffnet eine Nachrichtenunterhaltung",
        "it": "Apre una conversazione",
        "pl": "Otwiera rozmowę",
        "ru": "Открывает переписку",
        "sq": "Hap një bisedë mesazhesh",
        "zh-Hans": "打开私信对话",
        "nl": "Opent een berichtengesprek",
    },
    "chat_fans_live_now_view_profile_a11y": {
        "en": "View profile",
        "es": "Ver perfil",
        "fr": "Voir le profil",
        "pt": "Ver perfil",
        "de": "Profil ansehen",
        "it": "Vedi profilo",
        "pl": "Zobacz profil",
        "ru": "Смотреть профиль",
        "sq": "Shiko profilin",
        "zh-Hans": "查看资料",
        "nl": "Bekijk profiel",
    },
}


def main() -> None:
    data = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    strings = data.setdefault("strings", {})
    for key, translations in ENTRIES.items():
        entry = strings.get(key) or {"extractionState": "manual", "localizations": {}}
        entry["extractionState"] = "manual"
        entry["localizations"] = locs(translations)
        strings[key] = entry
    XCSTRINGS.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"patched {len(ENTRIES)} Fans Live Now open-chat keys")


if __name__ == "__main__":
    main()
