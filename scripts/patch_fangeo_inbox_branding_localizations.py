#!/usr/bin/env python3
"""User-facing rename: Action Center → FanGeo Inbox.

Keeps localization keys (`action_center_*`) and Swift symbols unchanged.
"""
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
    "action_center_title": {
        "en": "FanGeo Inbox",
        "es": "Bandeja FanGeo",
        "fr": "Boîte de réception FanGeo",
        "pt": "Caixa de entrada FanGeo",
        "de": "FanGeo-Posteingang",
        "it": "Posta in arrivo FanGeo",
        "pl": "Skrzynka FanGeo",
        "ru": "Входящие FanGeo",
        "sq": "Inbox FanGeo",
        "zh-Hans": "FanGeo 收件箱",
        "nl": "FanGeo-inbox",
    },
    "action_center_subtitle": {
        "en": "Your actions, updates, and notification history.",
        "es": "Tus acciones, actualizaciones e historial de notificaciones.",
        "fr": "Vos actions, mises à jour et historique de notifications.",
        "pt": "Suas ações, atualizações e histórico de notificações.",
        "de": "Deine Aktionen, Updates und dein Benachrichtigungsverlauf.",
        "it": "Le tue azioni, gli aggiornamenti e la cronologia delle notifiche.",
        "pl": "Twoje działania, aktualizacje i historia powiadomień.",
        "ru": "Ваши действия, обновления и история уведомлений.",
        "sq": "Veprimet, përditësimet dhe historia e njoftimeve tuaja.",
        "zh-Hans": "你的待办、动态与通知历史。",
        "nl": "Jouw acties, updates en notificatiegeschiedenis.",
    },
    "action_center_a11y_hint": {
        "en": "Open FanGeo Inbox",
        "es": "Abrir Bandeja FanGeo",
        "fr": "Ouvrir la boîte de réception FanGeo",
        "pt": "Abrir a caixa de entrada FanGeo",
        "de": "FanGeo-Posteingang öffnen",
        "it": "Apri la posta in arrivo FanGeo",
        "pl": "Otwórz Skrzynkę FanGeo",
        "ru": "Открыть входящие FanGeo",
        "sq": "Hap Inbox FanGeo",
        "zh-Hans": "打开 FanGeo 收件箱",
        "nl": "Open FanGeo-inbox",
    },
    "action_center_a11y_pending_format": {
        "en": "FanGeo Inbox. %lld pending.",
        "es": "Bandeja FanGeo. %lld pendientes.",
        "fr": "Boîte de réception FanGeo. %lld en attente.",
        "pt": "Caixa de entrada FanGeo. %lld pendentes.",
        "de": "FanGeo-Posteingang. %lld ausstehend.",
        "it": "Posta in arrivo FanGeo. %lld in sospeso.",
        "pl": "Skrzynka FanGeo. %lld oczekujących.",
        "ru": "Входящие FanGeo. %lld в ожидании.",
        "sq": "Inbox FanGeo. %lld në pritje.",
        "zh-Hans": "FanGeo 收件箱。有 %lld 项待处理。",
        "nl": "FanGeo-inbox. %lld openstaand.",
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
        "nl": "Sluit FanGeo-inbox",
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
        "nl": "FanGeo-inboxopties",
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
        "nl": "Verberg dit FanGeo-inboxitem",
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
        "nl": "Wis alle verbergbare FanGeo-inboxitems",
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
        "nl": "FanGeo-inbox wissen?",
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
        "nl": "Dit verwijdert verbergbare items uit je FanGeo-inbox. Games, events, Teams of andere activiteit worden niet verwijderd.",
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
        "nl": "Verwijderd uit FanGeo-inbox",
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
    print(f"patched {len(ENTRIES)} FanGeo Inbox branding keys")


if __name__ == "__main__":
    main()
