#!/usr/bin/env python3
"""Localization for Action Center Action Needed / Notifications tabs."""
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
    "action_center_tab_action_needed": {
        "en": "Action Needed",
        "es": "Acción necesaria",
        "fr": "Action requise",
        "pt": "Ação necessária",
        "de": "Aktion nötig",
        "it": "Azione richiesta",
        "pl": "Wymagane działanie",
        "ru": "Нужно действие",
        "sq": "Kërkohet veprim",
        "zh-Hans": "需要操作",
        "nl": "Actie nodig",
    },
    "action_center_tab_action_needed_subtitle": {
        "en": "Items that still need your decision.",
        "es": "Elementos que aún requieren tu decisión.",
        "fr": "Éléments qui nécessitent encore votre décision.",
        "pt": "Itens que ainda precisam da sua decisão.",
        "de": "Einträge, die noch deine Entscheidung brauchen.",
        "it": "Elementi che richiedono ancora la tua decisione.",
        "pl": "Elementy, które nadal wymagają Twojej decyzji.",
        "ru": "Элементы, по которым нужно ваше решение.",
        "sq": "Artikuj që ende kërkojnë vendimin tuaj.",
        "zh-Hans": "仍需你做出决定的事项。",
        "nl": "Items die nog jouw beslissing nodig hebben.",
    },
    "action_center_tab_notifications": {
        "en": "Notifications",
        "es": "Notificaciones",
        "fr": "Notifications",
        "pt": "Notificações",
        "de": "Benachrichtigungen",
        "it": "Notifiche",
        "pl": "Powiadomienia",
        "ru": "Уведомления",
        "sq": "Njoftime",
        "zh-Hans": "通知",
        "nl": "Meldingen",
    },
    "action_center_tab_notifications_subtitle": {
        "en": "Important updates stay here until you clear them.",
        "es": "Las actualizaciones importantes permanecen aquí hasta que las borres.",
        "fr": "Les mises à jour importantes restent ici jusqu’à ce que vous les effaciez.",
        "pt": "Atualizações importantes ficam aqui até você limpá-las.",
        "de": "Wichtige Updates bleiben hier, bis du sie löschst.",
        "it": "Gli aggiornamenti importanti restano qui finché non li cancelli.",
        "pl": "Ważne aktualizacje zostają tutaj, dopóki ich nie usuniesz.",
        "ru": "Важные обновления остаются здесь, пока вы их не очистите.",
        "sq": "Përditësimet e rëndësishme qëndrojnë këtu derisa t’i pastroni.",
        "zh-Hans": "重要更新会保留在这里，直到你清除。",
        "nl": "Belangrijke updates blijven hier tot je ze wist.",
    },
    "action_center_clear_all_notifications": {
        "en": "Clear All Notifications",
        "es": "Borrar todas las notificaciones",
        "fr": "Effacer toutes les notifications",
        "pt": "Limpar todas as notificações",
        "de": "Alle Benachrichtigungen löschen",
        "it": "Cancella tutte le notifiche",
        "pl": "Wyczyść wszystkie powiadomienia",
        "ru": "Очистить все уведомления",
        "sq": "Pastro të gjitha njoftimet",
        "zh-Hans": "清除全部通知",
        "nl": "Wis alle meldingen",
    },
    "action_center_clear_notifications_confirm_title": {
        "en": "Clear notification history?",
        "es": "¿Borrar el historial de notificaciones?",
        "fr": "Effacer l’historique des notifications ?",
        "pt": "Limpar o histórico de notificações?",
        "de": "Benachrichtigungsverlauf löschen?",
        "it": "Cancellare la cronologia notifiche?",
        "pl": "Wyczyścić historię powiadomień?",
        "ru": "Очистить историю уведомлений?",
        "sq": "Të pastrohet historia e njoftimeve?",
        "zh-Hans": "清除通知历史？",
        "nl": "Notificatiegeschiedenis wissen?",
    },
    "action_center_clear_notifications_confirm_message": {
        "en": "This clears Notifications only. Action Needed items are unchanged.",
        "es": "Esto borra solo Notificaciones. Acción necesaria no cambia.",
        "fr": "Ceci efface uniquement Notifications. Action requise reste inchangée.",
        "pt": "Isso limpa apenas Notificações. Ação necessária permanece igual.",
        "de": "Dies löscht nur Benachrichtigungen. Aktion nötig bleibt unverändert.",
        "it": "Questo cancella solo Notifiche. Azione richiesta non cambia.",
        "pl": "To czyści tylko Powiadomienia. Wymagane działanie bez zmian.",
        "ru": "Очищаются только уведомления. Нужные действия не меняются.",
        "sq": "Kjo pastron vetëm Njoftimet. Veprimi i kërkuar nuk ndryshon.",
        "zh-Hans": "这只会清除通知。需要操作的事项保持不变。",
        "nl": "Dit wist alleen Meldingen. Actie nodig blijft ongewijzigd.",
    },
    "action_center_notifications_empty_title": {
        "en": "No notifications",
        "es": "Sin notificaciones",
        "fr": "Aucune notification",
        "pt": "Sem notificações",
        "de": "Keine Benachrichtigungen",
        "it": "Nessuna notifica",
        "pl": "Brak powiadomień",
        "ru": "Нет уведомлений",
        "sq": "Nuk ka njoftime",
        "zh-Hans": "暂无通知",
        "nl": "Geen meldingen",
    },
    "action_center_notifications_empty_body": {
        "en": "Team updates and other alerts will appear here.",
        "es": "Las actualizaciones del equipo y otras alertas aparecerán aquí.",
        "fr": "Les mises à jour d’équipe et autres alertes apparaîtront ici.",
        "pt": "Atualizações da equipe e outros alertas aparecerão aqui.",
        "de": "Team-Updates und andere Hinweise erscheinen hier.",
        "it": "Qui appariranno aggiornamenti del team e altri avvisi.",
        "pl": "Tutaj pojawią się aktualizacje drużyny i inne alerty.",
        "ru": "Здесь появятся обновления команды и другие оповещения.",
        "sq": "Përditësimet e ekipit dhe njoftime të tjera do të shfaqen këtu.",
        "zh-Hans": "团队更新和其他提醒会显示在这里。",
        "nl": "Teamupdates en andere meldingen verschijnen hier.",
    },
    "action_center_unread_a11y": {
        "en": "Unread",
        "es": "No leído",
        "fr": "Non lu",
        "pt": "Não lido",
        "de": "Ungelesen",
        "it": "Non letto",
        "pl": "Nieprzeczytane",
        "ru": "Непрочитано",
        "sq": "E palexuar",
        "zh-Hans": "未读",
        "nl": "Ongelezen",
    },
    "action_center_notification_title_passthrough_format": {
        "en": "%@",
        "es": "%@",
        "fr": "%@",
        "pt": "%@",
        "de": "%@",
        "it": "%@",
        "pl": "%@",
        "ru": "%@",
        "sq": "%@",
        "zh-Hans": "%@",
        "nl": "%@",
    },
    "action_center_notification_subtitle_default": {
        "en": "Tap to open",
        "es": "Toca para abrir",
        "fr": "Appuyez pour ouvrir",
        "pt": "Toque para abrir",
        "de": "Tippen zum Öffnen",
        "it": "Tocca per aprire",
        "pl": "Dotknij, aby otworzyć",
        "ru": "Нажмите, чтобы открыть",
        "sq": "Trokit për të hapur",
        "zh-Hans": "点按打开",
        "nl": "Tik om te openen",
    },
}


def main() -> None:
    data = json.loads(XCSTRINGS.read_text())
    strings = data.setdefault("strings", {})
    for key, translations in ENTRIES.items():
        strings[key] = {"localizations": locs(translations)}
    XCSTRINGS.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    print(f"patched {len(ENTRIES)} keys")


if __name__ == "__main__":
    main()
