#!/usr/bin/env python3
"""Localization for Action Center dismiss / clear / undo."""
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
    "action_center_dismiss": {
        "en": "Dismiss",
        "es": "Descartar",
        "fr": "Ignorer",
        "pt": "Dispensar",
        "de": "Ausblenden",
        "it": "Ignora",
        "pl": "Odrzuć",
        "ru": "Скрыть",
        "sq": "Hiqe",
        "zh-Hans": "忽略",
    },
    "action_center_dismiss_item_a11y": {
        "en": "Dismiss this FanGeo Inbox item",
        "es": "Descartar este elemento de Bandeja FanGeo",
        "fr": "Ignorer cet élément de la boîte de réception FanGeo",
        "pt": "Dispensar este item da caixa de entrada FanGeo",
        "de": "Dieses Element im FanGeo-Posteingang ausblenden",
        "it": "Ignora questo elemento della posta in arrivo FanGeo",
        "pl": "Ukryj ten element Skrzynki FanGeo",
        "ru": "Скрыть этот элемент входящих FanGeo",
        "sq": "Hiqe këtë element të Inbox FanGeo",
        "zh-Hans": "忽略此 FanGeo 收件箱项目",
    },
    "action_center_removed_toast": {
        "en": "Removed from FanGeo Inbox",
        "es": "Eliminado de Bandeja FanGeo",
        "fr": "Retiré de la boîte de réception FanGeo",
        "pt": "Removido da caixa de entrada FanGeo",
        "de": "Aus dem FanGeo-Posteingang entfernt",
        "it": "Rimosso dalla posta in arrivo FanGeo",
        "pl": "Usunięto ze Skrzynki FanGeo",
        "ru": "Удалено из входящих FanGeo",
        "sq": "U hoq nga Inbox FanGeo",
        "zh-Hans": "已从 FanGeo 收件箱移除",
    },
    "action_center_undo": {
        "en": "Undo",
        "es": "Deshacer",
        "fr": "Annuler",
        "pt": "Desfazer",
        "de": "Rückgängig",
        "it": "Annulla",
        "pl": "Cofnij",
        "ru": "Отменить",
        "sq": "Zhbëj",
        "zh-Hans": "撤销",
    },
    "action_center_clear_all": {
        "en": "Clear All",
        "es": "Borrar todo",
        "fr": "Tout effacer",
        "pt": "Limpar tudo",
        "de": "Alle löschen",
        "it": "Cancella tutto",
        "pl": "Wyczyść wszystko",
        "ru": "Очистить все",
        "sq": "Pastro të gjitha",
        "zh-Hans": "全部清除",
    },
    "action_center_clear_all_a11y": {
        "en": "Clear all dismissible FanGeo Inbox items",
        "es": "Borrar todos los elementos descartables de Bandeja FanGeo",
        "fr": "Effacer tous les éléments ignorables de la boîte de réception FanGeo",
        "pt": "Limpar todos os itens dispensáveis da caixa de entrada FanGeo",
        "de": "Alle ausblendbaren Elemente im FanGeo-Posteingang löschen",
        "it": "Cancella tutti gli elementi ignorabili della posta in arrivo FanGeo",
        "pl": "Wyczyść wszystkie ukrywalne elementy Skrzynki FanGeo",
        "ru": "Очистить все скрываемые элементы входящих FanGeo",
        "sq": "Pastro të gjitha elementet e heqshme të Inbox FanGeo",
        "zh-Hans": "清除所有可忽略的 FanGeo 收件箱项目",
    },
    "action_center_options_a11y": {
        "en": "FanGeo Inbox options",
        "es": "Opciones de Bandeja FanGeo",
        "fr": "Options de la boîte de réception FanGeo",
        "pt": "Opções da caixa de entrada FanGeo",
        "de": "Optionen für den FanGeo-Posteingang",
        "it": "Opzioni della posta in arrivo FanGeo",
        "pl": "Opcje Skrzynki FanGeo",
        "ru": "Параметры входящих FanGeo",
        "sq": "Opsionet e Inbox FanGeo",
        "zh-Hans": "FanGeo 收件箱选项",
    },
    "action_center_close_a11y": {
        "en": "Close FanGeo Inbox",
        "es": "Cerrar Bandeja FanGeo",
        "fr": "Fermer la boîte de réception FanGeo",
        "pt": "Fechar a caixa de entrada FanGeo",
        "de": "FanGeo-Posteingang schließen",
        "it": "Chiudi la posta in arrivo FanGeo",
        "pl": "Zamknij Skrzynkę FanGeo",
        "ru": "Закрыть входящие FanGeo",
        "sq": "Mbyll Inbox FanGeo",
        "zh-Hans": "关闭 FanGeo 收件箱",
    },
    "action_center_clear_confirm_title": {
        "en": "Clear FanGeo Inbox?",
        "es": "¿Borrar Bandeja FanGeo?",
        "fr": "Effacer la boîte de réception FanGeo ?",
        "pt": "Limpar a caixa de entrada FanGeo?",
        "de": "FanGeo-Posteingang leeren?",
        "it": "Cancellare la posta in arrivo FanGeo?",
        "pl": "Wyczyścić Skrzynkę FanGeo?",
        "ru": "Очистить входящие FanGeo?",
        "sq": "Të pastrohet Inbox FanGeo?",
        "zh-Hans": "清除 FanGeo 收件箱？",
    },
    "action_center_clear_confirm_message": {
        "en": "This removes dismissible items from your FanGeo Inbox. It does not delete games, events, Teams, or other activity.",
        "es": "Esto quita los elementos descartables de tu Bandeja FanGeo. No elimina partidos, eventos, equipos ni otra actividad.",
        "fr": "Cela retire les éléments ignorables de votre boîte de réception FanGeo. Cela ne supprime pas les matchs, événements, équipes ni les autres activités.",
        "pt": "Isso remove itens dispensáveis da sua caixa de entrada FanGeo. Não exclui jogos, eventos, equipes nem outras atividades.",
        "de": "Dadurch werden ausblendbare Elemente aus deinem FanGeo-Posteingang entfernt. Spiele, Events, Teams oder andere Aktivitäten werden nicht gelöscht.",
        "it": "Questo rimuove gli elementi ignorabili dalla posta in arrivo FanGeo. Non elimina partite, eventi, squadre o altre attività.",
        "pl": "To usuwa ukrywalne elementy ze Skrzynki FanGeo. Nie usuwa gier, wydarzeń, drużyn ani innej aktywności.",
        "ru": "Это убирает скрываемые элементы из входящих FanGeo. Игры, события, команды и другая активность не удаляются.",
        "sq": "Kjo heq elementet e heqshme nga Inbox FanGeo. Nuk fshin lojëra, ngjarje, ekipe ose aktivitet tjetër.",
        "zh-Hans": "这会从 FanGeo 收件箱移除可忽略的项目。不会删除比赛、活动、队伍或其他动态。",
    },
    "action_center_caught_up_title": {
        "en": "You’re all caught up",
        "es": "Estás al día",
        "fr": "Vous êtes à jour",
        "pt": "Você está em dia",
        "de": "Du bist auf dem Laufenden",
        "it": "Sei in pari",
        "pl": "Jesteś na bieżąco",
        "ru": "Вы всё сделали",
        "sq": "Je plotësisht i përditësuar",
        "zh-Hans": "全部处理完毕",
    },
    "action_center_caught_up_body": {
        "en": "There’s nothing that needs your attention right now.",
        "es": "No hay nada que requiera tu atención ahora.",
        "fr": "Rien ne demande votre attention pour le moment.",
        "pt": "Não há nada que precise da sua atenção agora.",
        "de": "Im Moment braucht nichts deine Aufmerksamkeit.",
        "it": "Al momento non c’è nulla che richieda la tua attenzione.",
        "pl": "W tej chwili nic nie wymaga Twojej uwagi.",
        "ru": "Сейчас нет ничего, что требовало бы вашего внимания.",
        "sq": "Nuk ka asgjë që kërkon vëmendjen tuaj tani.",
        "zh-Hans": "目前没有需要你关注的事项。",
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
