#!/usr/bin/env python3
"""Layered membership-error copy + Myself access-only caption."""
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
    "fan_teams_membership_update_failed": {
        "en": "Couldn't update your Team membership. Please try again.",
        "es": "No se pudo actualizar tu membresía del equipo. Inténtalo de nuevo.",
        "fr": "Impossible de mettre à jour votre appartenance à l’équipe. Veuillez réessayer.",
        "pt": "Não foi possível atualizar sua participação na equipe. Tente novamente.",
        "de": "Deine Team-Mitgliedschaft konnte nicht aktualisiert werden. Bitte versuche es erneut.",
        "it": "Impossibile aggiornare la tua appartenenza al Team. Riprova.",
        "pl": "Nie udało się zaktualizować członkostwa w zespole. Spróbuj ponownie.",
        "ru": "Не удалось обновить членство в команде. Попробуйте ещё раз.",
        "sq": "Nuk mund të përditësohej anëtarësia e ekipit. Ju lutemi provoni përsëri.",
        "zh-Hans": "无法更新你的队伍成员身份。请重试。",
    },
    "fan_teams_detail_reload_failed": {
        "en": "Couldn't reload this Team. Please try again.",
        "es": "No se pudo recargar este equipo. Inténtalo de nuevo.",
        "fr": "Impossible de recharger cette équipe. Veuillez réessayer.",
        "pt": "Não foi possível recarregar esta equipe. Tente novamente.",
        "de": "Dieses Team konnte nicht neu geladen werden. Bitte versuche es erneut.",
        "it": "Impossibile ricaricare questo Team. Riprova.",
        "pl": "Nie udało się ponownie wczytać tej drużyny. Spróbuj ponownie.",
        "ru": "Не удалось обновить эту команду. Попробуйте ещё раз.",
        "sq": "Nuk mund të ringarkohej ky ekip. Ju lutemi provoni përsëri.",
        "zh-Hans": "无法重新加载此队伍。请重试。",
    },
    "team_player_membership_status_not_on_team_as_player": {
        "en": "Not on Team as player",
        "es": "No está en el equipo como jugador",
        "fr": "Pas dans l’équipe en tant que joueur",
        "pt": "Não está na equipe como jogador",
        "de": "Nicht als Spieler im Team",
        "it": "Non in squadra come giocatore",
        "pl": "Nie w drużynie jako zawodnik",
        "ru": "Не в команде как игрок",
        "sq": "Jo në ekip si lojtar",
        "zh-Hans": "未作为球员在队",
    },
}


def main() -> None:
    data = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    strings = data.setdefault("strings", {})
    for key, translations in ENTRIES.items():
        entry = strings.get(key, {})
        entry["localizations"] = locs(translations)
        strings[key] = entry
    XCSTRINGS.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"patched {len(ENTRIES)} keys")


if __name__ == "__main__":
    main()
