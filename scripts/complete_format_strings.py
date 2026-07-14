#!/usr/bin/env python3
"""Complete format-string and remaining catalog localizations."""
from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
XCSTRINGS = ROOT / "GameOn" / "Localizable.xcstrings"
SUPPORTED = ["en", "es", "fr", "pt", "de", "it", "pl", "ru", "sq", "zh-Hans"]


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


WORD_MAP = {
    "venues": {"es": "locales", "fr": "lieux", "pt": "locais", "de": "Standorte", "it": "locali", "pl": "lokalizacje", "ru": "площадок", "sq": "vende", "zh-Hans": "个场馆"},
    "venue": {"es": "local", "fr": "lieu", "pt": "local", "de": "Standort", "it": "locale", "pl": "lokalizacja", "ru": "площадка", "sq": "vend", "zh-Hans": "场馆"},
    "games": {"es": "partidos", "fr": "matchs", "pt": "jogos", "de": "Spiele", "it": "partite", "pl": "mecze", "ru": "игр", "sq": "ndeshje", "zh-Hans": "场比赛"},
    "game": {"es": "partido", "fr": "match", "pt": "jogo", "de": "Spiel", "it": "partita", "pl": "mecz", "ru": "игра", "sq": "ndeshje", "zh-Hans": "场比赛"},
    "players": {"es": "jugadores", "fr": "joueurs", "pt": "jogadores", "de": "Spieler", "it": "giocatori", "pl": "graczy", "ru": "игроков", "sq": "lojtarë", "zh-Hans": "名球员"},
    "player": {"es": "jugador", "fr": "joueur", "pt": "jogador", "de": "Spieler", "it": "giocatore", "pl": "gracz", "ru": "игрок", "sq": "lojtar", "zh-Hans": "名球员"},
    "fans": {"es": "fans", "fr": "fans", "pt": "fãs", "de": "Fans", "it": "fan", "pl": "kibiców", "ru": "фанатов", "sq": "tifozë", "zh-Hans": "名球迷"},
    "fan": {"es": "fan", "fr": "fan", "pt": "fã", "de": "Fan", "it": "fan", "pl": "kibic", "ru": "фанат", "sq": "tifoz", "zh-Hans": "名球迷"},
    "messages": {"es": "mensajes", "fr": "messages", "pt": "mensagens", "de": "Nachrichten", "it": "messaggi", "pl": "wiadomości", "ru": "сообщений", "sq": "mesazhe", "zh-Hans": "条消息"},
    "selected": {"es": "seleccionados", "fr": "sélectionnés", "pt": "selecionados", "de": "ausgewählt", "it": "selezionati", "pl": "wybrano", "ru": "выбрано", "sq": "të zgjedhur", "zh-Hans": "已选"},
    "Going": {"es": "Van", "fr": "Y vont", "pt": "Vão", "de": "Gehen hin", "it": "Ci vanno", "pl": "Idzie", "ru": "Идут", "sq": "Po shkojnë", "zh-Hans": "要去"},
    "going": {"es": "van", "fr": "y vont", "pt": "vão", "de": "gehen hin", "it": "ci vanno", "pl": "idzie", "ru": "идут", "sq": "po shkojnë", "zh-Hans": "要去"},
    "votes": {"es": "votos", "fr": "votes", "pt": "votos", "de": "Stimmen", "it": "voti", "pl": "głosów", "ru": "голосов", "sq": "vota", "zh-Hans": "票"},
    "voted": {"es": "votaron", "fr": "ont voté", "pt": "votaram", "de": "stimmten ab", "it": "hanno votato", "pl": "zagłosowało", "ru": "проголосовали", "sq": "votuan", "zh-Hans": "名球迷投票"},
    "watch parties": {"es": "watch parties", "fr": "watch parties", "pt": "watch parties", "de": "Watch Parties", "it": "watch party", "pl": "watch party", "ru": "watch party", "sq": "watch party", "zh-Hans": "场观赛聚会"},
    "pickup games": {"es": "partidos pickup", "fr": "matchs pickup", "pt": "jogos pickup", "de": "Pickup-Spiele", "it": "partite pickup", "pl": "mecze pickup", "ru": "pickup-игр", "sq": "ndeshje pickup", "zh-Hans": "场临时赛"},
    "pickup game invites": {"es": "invitaciones a partidos pickup", "fr": "invitations à des matchs pickup", "pt": "convites para jogos pickup", "de": "Pickup-Spiel-Einladungen", "it": "inviti a partite pickup", "pl": "zaproszenia do meczów pickup", "ru": "приглашений на pickup-игры", "sq": "ftesa për ndeshje pickup", "zh-Hans": "条临时赛邀请"},
    "mutual fans": {"es": "fans en común", "fr": "fans en commun", "pt": "fãs em comum", "de": "gemeinsame Fans", "it": "fan in comune", "pl": "wspólnych kibiców", "ru": "общих фанатов", "sq": "tifozë të përbashkët", "zh-Hans": "名共同球迷"},
    "options": {"es": "opciones", "fr": "options", "pt": "opções", "de": "Optionen", "it": "opzioni", "pl": "opcji", "ru": "вариантов", "sq": "opsione", "zh-Hans": "个选项"},
    "stars": {"es": "estrellas", "fr": "étoiles", "pt": "estrelas", "de": "Sterne", "it": "stelle", "pl": "gwiazdek", "ru": "звёзд", "sq": "yje", "zh-Hans": "星"},
    "reactions": {"es": "reacciones", "fr": "réactions", "pt": "reações", "de": "Reaktionen", "it": "reazioni", "pl": "reakcji", "ru": "реакций", "sq": "reagime", "zh-Hans": "条反应"},
    "total": {"es": "total", "fr": "total", "pt": "total", "de": "gesamt", "it": "totale", "pl": "łącznie", "ru": "всего", "sq": "gjithsej", "zh-Hans": "总计"},
    "unread messages": {"es": "mensajes no leídos", "fr": "messages non lus", "pt": "mensagens não lidas", "de": "ungelesene Nachrichten", "it": "messaggi non letti", "pl": "nieprzeczytanych wiadomości", "ru": "непрочитанных сообщений", "sq": "mesazhe të palexuara", "zh-Hans": "条未读消息"},
    "more players": {"es": "jugadores más", "fr": "joueurs de plus", "pt": "jogadores a mais", "de": "weitere Spieler", "it": "giocatori in più", "pl": "więcej graczy", "ru": "ещё игроков", "sq": "lojtarë më shumë", "zh-Hans": "更多球员"},
    "invited you": {"es": "te invitó", "fr": "vous a invité", "pt": "convidou você", "de": "hat dich eingeladen", "it": "ti ha invitato", "pl": "zaprosił Cię", "ru": "пригласил вас", "sq": "të ftoi", "zh-Hans": "邀请了你"},
    "invited you to": {"es": "te invitó a", "fr": "vous a invité à", "pt": "convidou você para", "de": "hat dich eingeladen zu", "it": "ti ha invitato a", "pl": "zaprosił Cię do", "ru": "пригласил вас на", "sq": "të ftoi në", "zh-Hans": "邀请你参加"},
    "profile": {"es": "perfil", "fr": "profil", "pt": "perfil", "de": "Profil", "it": "profilo", "pl": "profil", "ru": "профиль", "sq": "profil", "zh-Hans": "资料"},
    "Organizer": {"es": "Organizador", "fr": "Organisateur", "pt": "Organizador", "de": "Organisator", "it": "Organizzatore", "pl": "Organizator", "ru": "Организатор", "sq": "Organizues", "zh-Hans": "组织者"},
    "club crest": {"es": "escudo del club", "fr": "blason du club", "pt": "brasão do clube", "de": "Vereinswappen", "it": "stemma del club", "pl": "herb klubu", "ru": "эмблема клуба", "sq": "stemë klubi", "zh-Hans": "俱乐部徽章"},
    "Watch Spot": {"es": "Watch Spot", "fr": "Watch Spot", "pt": "Watch Spot", "de": "Watch Spot", "it": "Watch Spot", "pl": "Watch Spot", "ru": "Watch Spot", "sq": "Watch Spot", "zh-Hans": "观赛点"},
    "is My Team": {"es": "es mi equipo", "fr": "est mon équipe", "pt": "é meu time", "de": "ist mein Team", "it": "è la mia squadra", "pl": "to moja drużyna", "ru": "— моя команда", "sq": "është ekipi im", "zh-Hans": "是我的球队"},
    "players waiting": {"es": "jugadores en espera", "fr": "joueurs en attente", "pt": "jogadores aguardando", "de": "wartende Spieler", "it": "giocatori in attesa", "pl": "graczy czeka", "ru": "игроков ждут", "sq": "lojtarë në pritje", "zh-Hans": "名球员等待中"},
    "players waiting. Tap to review.": {
        "es": "jugadores en espera. Toca para revisar.", "fr": "joueurs en attente. Touchez pour examiner.",
        "pt": "jogadores aguardando. Toque para revisar.", "de": "wartende Spieler. Tippen zum Prüfen.",
        "it": "giocatori in attesa. Tocca per rivedere.", "pl": "graczy czeka. Dotknij, aby sprawdzić.",
        "ru": "игроков ждут. Нажмите для просмотра.", "sq": "lojtarë në pritje. Prek për të shqyrtuar.", "zh-Hans": "名球员等待中。点按查看。",
    },
    "players asked to join games you host — review below.": {
        "es": "jugadores pidieron unirse a tus partidos — revísalos abajo.",
        "fr": "joueurs ont demandé à rejoindre vos matchs — consultez ci-dessous.",
        "pt": "jogadores pediram para entrar nos seus jogos — revise abaixo.",
        "de": "Spieler möchten deinen Spielen beitreten — unten prüfen.",
        "it": "giocatori hanno chiesto di unirti alle tue partite — controlla sotto.",
        "pl": "graczy poprosiło o dołączenie do twoich meczów — sprawdź poniżej.",
        "ru": "игроков попросили присоединиться к вашим играм — см. ниже.",
        "sq": "lojtarë kërkuan të bashkohen në ndeshjet tuaja — shqyrtoni më poshtë.",
        "zh-Hans": "名球员请求加入你主办的赛事 — 请在下方查看。",
    },
    "rows failed during insert and were skipped.": {
        "es": "filas fallaron al insertar y se omitieron.",
        "fr": "lignes ont échoué à l’insertion et ont été ignorées.",
        "pt": "linhas falharam na inserção e foram ignoradas.",
        "de": "Zeilen konnten nicht eingefügt werden und wurden übersprungen.",
        "it": "righe non inserite e saltate.",
        "pl": "wierszy nie udało się dodać i pominięto.",
        "ru": "строк не удалось вставить и они пропущены.",
        "sq": "rreshta dështuan gjatë futjes dhe u anashkaluan.",
        "zh-Hans": "行插入失败并已跳过。",
    },
    "selected for import": {
        "es": "seleccionados para importar", "fr": "sélectionnés pour l’import",
        "pt": "selecionados para importação", "de": "zum Import ausgewählt",
        "it": "selezionati per l’importazione", "pl": "wybrano do importu",
        "ru": "выбрано для импорта", "sq": "të zgjedhur për import", "zh-Hans": "已选待导入",
    },
    "shared teams": {
        "es": "equipos en común", "fr": "équipes communes", "pt": "times em comum",
        "de": "gemeinsame Teams", "it": "squadre in comune", "pl": "wspólnych drużyn",
        "ru": "общих команд", "sq": "ekipe të përbashkëta", "zh-Hans": "支共同球队",
    },
    "interested / going": {
        "es": "interesados / van", "fr": "intéressés / y vont", "pt": "interessados / vão",
        "de": "interessiert / gehen hin", "it": "interessati / ci vanno", "pl": "zainteresowanych / idzie",
        "ru": "заинтересованы / идут", "sq": "të interesuar / po shkojnë", "zh-Hans": "感兴趣 / 要去",
    },
    "pickup activity items": {
        "es": "elementos de actividad pickup", "fr": "éléments d’activité pickup", "pt": "itens de atividade pickup",
        "de": "Pickup-Aktivitätseinträge", "it": "elementi attività pickup", "pl": "elementów aktywności pickup",
        "ru": "элементов pickup-активности", "sq": "artikuj aktiviteti pickup", "zh-Hans": "条临时赛动态",
    },
    "pickup places": {
        "es": "lugares pickup", "fr": "lieux pickup", "pt": "locais pickup", "de": "Pickup-Orte",
        "it": "luoghi pickup", "pl": "miejsc pickup", "ru": "pickup-мест", "sq": "vende pickup", "zh-Hans": "个临时赛地点",
    },
    "games at this venue": {
        "es": "partidos en este local", "fr": "matchs dans ce lieu", "pt": "jogos neste local",
        "de": "Spiele an diesem Standort", "it": "partite in questo locale", "pl": "meczów w tej lokalizacji",
        "ru": "игр на этой площадке", "sq": "ndeshje në këtë vend", "zh-Hans": "场赛事在此场馆",
    },
    "games today": {
        "es": "partidos hoy", "fr": "matchs aujourd’hui", "pt": "jogos hoje", "de": "Spiele heute",
        "it": "partite oggi", "pl": "meczów dziś", "ru": "игр сегодня", "sq": "ndeshje sot", "zh-Hans": "场比赛今天",
    },
}


def translate_format(en: str, lang: str) -> str:
    if en in WORD_MAP and isinstance(WORD_MAP[en], dict):
        return WORD_MAP[en].get(lang, en)
    out = en
    # longest phrases first
    for phrase, mapping in sorted(WORD_MAP.items(), key=lambda x: -len(x[0])):
        if phrase in out and isinstance(mapping, dict) and lang in mapping:
            out = out.replace(phrase, mapping[lang])
    return out


def is_ui_key(key: str) -> bool:
    if not key or len(key.strip()) < 2:
        return False
    if key in {"@alexmorgan", "@fangeosports", "you@email.com"}:
        return False
    return True


def main() -> None:
    data = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    strings = data["strings"]
    added = 0

    for key, entry in strings.items():
        if not is_ui_key(key):
            continue
        locs = entry.setdefault("localizations", {})
        en_value = locs.get("en", {}).get("stringUnit", {}).get("value", key)
        missing = [lang for lang in SUPPORTED if lang not in locs]
        if not missing:
            continue
        for lang in missing:
            if lang == "en":
                locs[lang] = unit(key if en_value == key else en_value)
            else:
                locs[lang] = unit(translate_format(en_value, lang))
            added += 1
        entry["extractionState"] = "manual"

    XCSTRINGS.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Added locale entries: {added}")


if __name__ == "__main__":
    main()
