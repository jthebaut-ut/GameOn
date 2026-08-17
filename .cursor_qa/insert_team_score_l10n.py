#!/usr/bin/env python3
"""Insert team_score_* localization keys. Does not reorder the catalog."""
from pathlib import Path

PATH = Path("/Users/jthebaut/Desktop/GameOn_RECOVERY_FINAL/GameOn/GameOn/Localizable.xcstrings")

LANGS = ["de", "en", "es", "fr", "it", "pl", "pt", "ru", "sq", "zh-Hans"]

KEYS = {
    "team_score_who_scored": {
        "en": "Who scored?",
        "es": "¿Quién anotó?",
        "fr": "Qui a marqué ?",
        "pt": "Quem marcou?",
        "de": "Wer hat getroffen?",
        "it": "Chi ha segnato?",
        "pl": "Kto zdobył punkt?",
        "ru": "Кто забил?",
        "sq": "Kush shënoi?",
        "zh-Hans": "谁得分了？",
    },
    "team_score_skip_scorer": {
        "en": "Unknown / Skip",
        "es": "Desconocido / Omitir",
        "fr": "Inconnu / Ignorer",
        "pt": "Desconhecido / Ignorar",
        "de": "Unbekannt / Überspringen",
        "it": "Sconosciuto / Salta",
        "pl": "Nieznany / Pomiń",
        "ru": "Неизвестно / Пропустить",
        "sq": "I panjohur / Anashkalo",
        "zh-Hans": "未知 / 跳过",
    },
    "team_score_goal_by": {
        "en": "Goal scorer",
        "es": "Autor del gol",
        "fr": "Buteur",
        "pt": "Autor do golo",
        "de": "Torschütze",
        "it": "Marcatore",
        "pl": "Strzelec gola",
        "ru": "Автор гола",
        "sq": "Shënuesi i golit",
        "zh-Hans": "进球球员",
    },
    "team_score_run_scored_by": {
        "en": "Who scored the run?",
        "es": "¿Quién anotó la carrera?",
        "fr": "Qui a marqué le point ?",
        "pt": "Quem anotou a corrida?",
        "de": "Wer hat den Run erzielt?",
        "it": "Chi ha segnato il punto?",
        "pl": "Kto zdobył runa?",
        "ru": "Кто принёс ран?",
        "sq": "Kush shënoi vrapimin?",
        "zh-Hans": "谁跑回本垒得分？",
    },
    "team_score_scored_by": {
        "en": "Scored by",
        "es": "Anotó",
        "fr": "Marqué par",
        "pt": "Marcado por",
        "de": "Erzielt von",
        "it": "Segnato da",
        "pl": "Zdobyte przez",
        "ru": "Набрал очки",
        "sq": "Shënuar nga",
        "zh-Hans": "得分者",
    },
    "team_score_score_by": {
        "en": "Score by",
        "es": "Punto de",
        "fr": "Point de",
        "pt": "Ponto de",
        "de": "Punkt von",
        "it": "Punto di",
        "pl": "Punkt dla",
        "ru": "Очки от",
        "sq": "Pikë nga",
        "zh-Hans": "得分来自",
    },
    "team_score_scorer": {
        "en": "Scorer",
        "es": "Anotador",
        "fr": "Buteur",
        "pt": "Marcador",
        "de": "Torschütze",
        "it": "Marcatore",
        "pl": "Strzelec",
        "ru": "Автор гола",
        "sq": "Shënuesi",
        "zh-Hans": "得分球员",
    },
    "team_score_unknown_scorer": {
        "en": "Unknown",
        "es": "Desconocido",
        "fr": "Inconnu",
        "pt": "Desconhecido",
        "de": "Unbekannt",
        "it": "Sconosciuto",
        "pl": "Nieznany",
        "ru": "Неизвестно",
        "sq": "I panjohur",
        "zh-Hans": "未知",
    },
    "team_score_skip_scorer_a11y": {
        "en": "Unknown, skip scorer",
        "es": "Desconocido, omitir anotador",
        "fr": "Inconnu, ignorer le buteur",
        "pt": "Desconhecido, ignorar marcador",
        "de": "Unbekannt, Torschützen überspringen",
        "it": "Sconosciuto, salta marcatore",
        "pl": "Nieznany, pomiń strzelca",
        "ru": "Неизвестно, пропустить автора гола",
        "sq": "I panjohur, anashkalo shënuesin",
        "zh-Hans": "未知，跳过得分球员",
    },
    "team_score_goal_title_format": {
        "en": "Goal — %@",
        "es": "Gol — %@",
        "fr": "But — %@",
        "pt": "Golo — %@",
        "de": "Tor — %@",
        "it": "Gol — %@",
        "pl": "Gol — %@",
        "ru": "Гол — %@",
        "sq": "Gol — %@",
        "zh-Hans": "进球 — %@",
    },
    "team_score_run_title_format": {
        "en": "Run scored — %@",
        "es": "Carrera anotada — %@",
        "fr": "Point marqué — %@",
        "pt": "Corrida anotada — %@",
        "de": "Run erzielt — %@",
        "it": "Punto segnato — %@",
        "pl": "Run zdobyty — %@",
        "ru": "Ран — %@",
        "sq": "Vrapim i shënuar — %@",
        "zh-Hans": "跑垒得分 — %@",
    },
    "team_score_player_scored_format": {
        "en": "%@ scored",
        "es": "%@ anotó",
        "fr": "%@ a marqué",
        "pt": "%@ marcou",
        "de": "%@ hat getroffen",
        "it": "%@ ha segnato",
        "pl": "%@ zdobył punkty",
        "ru": "%@ набрал очки",
        "sq": "%@ shënoi",
        "zh-Hans": "%@ 得分",
    },
    "team_score_generic_title_format": {
        "en": "Score — %@",
        "es": "Punto — %@",
        "fr": "Point — %@",
        "pt": "Ponto — %@",
        "de": "Punkt — %@",
        "it": "Punto — %@",
        "pl": "Punkt — %@",
        "ru": "Очки — %@",
        "sq": "Pikë — %@",
        "zh-Hans": "得分 — %@",
    },
    "team_score_team_scored_format": {
        "en": "%@ scored",
        "es": "%@ anotó",
        "fr": "%@ a marqué",
        "pt": "%@ marcou",
        "de": "%@ hat getroffen",
        "it": "%@ ha segnato",
        "pl": "%@ zdobył punkty",
        "ru": "%@ забил",
        "sq": "%@ shënoi",
        "zh-Hans": "%@ 得分",
    },
    "team_score_line": {
        "en": "Score",
        "es": "Marcador",
        "fr": "Score",
        "pt": "Placar",
        "de": "Spielstand",
        "it": "Punteggio",
        "pl": "Wynik",
        "ru": "Счёт",
        "sq": "Rezultati",
        "zh-Hans": "比分",
    },
}


def loc_block(values: dict) -> str:
    parts = []
    for lang in LANGS:
        value = values[lang].replace("\\", "\\\\").replace('"', '\\"')
        parts.append(
            "        \"%s\" : {\n"
            "          \"stringUnit\" : {\n"
            "            \"state\" : \"translated\",\n"
            "            \"value\" : \"%s\"\n"
            "          }\n"
            "        }" % (lang, value)
        )
    return ",\n".join(parts)


def key_block(key: str, values: dict) -> str:
    return (
        "    \"%s\" : {\n"
        "      \"extractionState\" : \"manual\",\n"
        "      \"localizations\" : {\n"
        "%s\n"
        "      }\n"
        "    }" % (key, loc_block(values))
    )


def main() -> None:
    text = PATH.read_text()
    minute = '"going_pro_live_minute_a11y_format"'
    assert minute in text
    # Protect the English "minute" value.
    assert '"value" : "minute"' in text
    blocks = []
    for key, values in KEYS.items():
        if f'"{key}" :' in text:
            print(f"skip existing {key}")
            continue
        blocks.append(key_block(key, values))
    if not blocks:
        print("nothing to add")
        return
    needle = "    }\n  },\n  \"version\" : \"1.1\"\n}"
    if needle not in text:
        raise SystemExit("catalog terminator not found")
    inserted = "    },\n" + ",\n".join(blocks) + "\n  },\n  \"version\" : \"1.1\"\n}"
    # The last key currently ends with `    }` then `  },`
    text = text.replace(needle, inserted, 1)
    PATH.write_text(text)
    out = PATH.read_text()
    assert '"going_pro_live_minute_a11y_format"' in out
    # Find the en value for that key still minute
    idx = out.find(minute)
    window = out[idx:idx + 800]
    assert '"value" : "minute"' in window, window
    for key in KEYS:
        assert f'"{key}" :' in out, key
    print(f"added {len(blocks)} keys")


if __name__ == "__main__":
    main()
