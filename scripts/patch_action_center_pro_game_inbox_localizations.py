#!/usr/bin/env python3
"""Composable FanGeo Inbox strings for professional-game score/final cards."""
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
    "action_center_pro_game_badge_score_update": {
        "en": "SCORE UPDATE",
        "es": "MARCADOR",
        "fr": "SCORE",
        "pt": "PLACAR",
        "de": "SPIELSTAND",
        "it": "PUNTEGGIO",
        "pl": "WYNIK",
        "ru": "СЧЁТ",
        "sq": "REZULTATI",
        "zh-Hans": "比分更新",
        "nl": "STAND",
    },
    "action_center_pro_game_badge_final": {
        "en": "FINAL",
        "es": "FINAL",
        "fr": "FINAL",
        "pt": "FINAL",
        "de": "ENDE",
        "it": "FINALE",
        "pl": "KONIEC",
        "ru": "ФИНАЛ",
        "sq": "FINALE",
        "zh-Hans": "终场",
        "nl": "EINDE",
    },
    "action_center_pro_game_badge_kickoff": {
        "en": "KICKOFF",
        "es": "INICIO",
        "fr": "COUP D’ENVOI",
        "pt": "INÍCIO",
        "de": "ANSTOSS",
        "it": "CALCIO D’INIZIO",
        "pl": "ROZPOCZĘCIE",
        "ru": "НАЧАЛО",
        "sq": "FILLIMI",
        "zh-Hans": "开球",
        "nl": "AFTRAP",
    },
    "action_center_pro_game_badge_halftime": {
        "en": "HALFTIME",
        "es": "DESCANSO",
        "fr": "MI-TEMPS",
        "pt": "INTERVALO",
        "de": "HALBZEIT",
        "it": "INTERVALLO",
        "pl": "PRZERWA",
        "ru": "ПЕРЕРЫВ",
        "sq": "PUSHIMI",
        "zh-Hans": "中场",
        "nl": "RUST",
    },
    "action_center_pro_game_scored_format": {
        "en": "%@ scored",
        "es": "%@ anotó",
        "fr": "%@ a marqué",
        "pt": "%@ marcou",
        "de": "%@ hat getroffen",
        "it": "%@ ha segnato",
        "pl": "%@ zdobył punkt",
        "ru": "%@ забил",
        "sq": "%@ shënoi",
        "zh-Hans": "%@得分",
        "nl": "%@ scoorde",
    },
    "action_center_pro_game_won_format": {
        "en": "%@ won",
        "es": "%@ ganó",
        "fr": "%@ a gagné",
        "pt": "%@ venceu",
        "de": "%@ hat gewonnen",
        "it": "%@ ha vinto",
        "pl": "%@ wygrał",
        "ru": "%@ победил",
        "sq": "%@ fitoi",
        "zh-Hans": "%@获胜",
        "nl": "%@ won",
    },
    "action_center_pro_game_draw": {
        "en": "Draw",
        "es": "Empate",
        "fr": "Match nul",
        "pt": "Empate",
        "de": "Unentschieden",
        "it": "Pareggio",
        "pl": "Remis",
        "ru": "Ничья",
        "sq": "Barazim",
        "zh-Hans": "平局",
        "nl": "Gelijkspel",
    },
    "action_center_pro_game_score_updated": {
        "en": "Score updated",
        "es": "Marcador actualizado",
        "fr": "Score mis à jour",
        "pt": "Placar atualizado",
        "de": "Spielstand aktualisiert",
        "it": "Punteggio aggiornato",
        "pl": "Wynik zaktualizowany",
        "ru": "Счёт обновлён",
        "sq": "Rezultati u përditësua",
        "zh-Hans": "比分已更新",
        "nl": "Stand bijgewerkt",
    },
    "action_center_pro_game_live": {
        "en": "LIVE",
        "es": "EN VIVO",
        "fr": "EN DIRECT",
        "pt": "AO VIVO",
        "de": "LIVE",
        "it": "LIVE",
        "pl": "NA ŻYWO",
        "ru": "ЭФИР",
        "sq": "LIVE",
        "zh-Hans": "直播",
        "nl": "LIVE",
    },
    "action_center_pro_game_starting_now": {
        "en": "Starting now",
        "es": "Empieza ahora",
        "fr": "Ça commence",
        "pt": "Começando agora",
        "de": "Startet jetzt",
        "it": "Inizia ora",
        "pl": "Zaczyna się teraz",
        "ru": "Начинается сейчас",
        "sq": "Fillon tani",
        "zh-Hans": "即将开始",
        "nl": "Begint nu",
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
