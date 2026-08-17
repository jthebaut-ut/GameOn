#!/usr/bin/env python3
"""Localizations for obvious Save/Unsave + Choose Location empty-state copy."""
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
    "team_location_choose_on_map": {
        "en": "Choose on map",
        "es": "Elegir en el mapa",
        "fr": "Choisir sur la carte",
        "pt": "Escolher no mapa",
        "de": "Auf der Karte wählen",
        "it": "Scegli sulla mappa",
        "pl": "Wybierz na mapie",
        "ru": "Выбрать на карте",
        "sq": "Zgjidh në hartë",
        "zh-Hans": "在地图上选择",
        "nl": "Kies op de kaart",
    },
    "team_location_saved_empty": {
        "en": "No saved locations yet.",
        "es": "Aún no hay ubicaciones guardadas.",
        "fr": "Aucun lieu enregistré pour le moment.",
        "pt": "Ainda não há locais salvos.",
        "de": "Noch keine gespeicherten Orte.",
        "it": "Nessun luogo salvato.",
        "pl": "Brak zapisanych lokalizacji.",
        "ru": "Пока нет сохранённых мест.",
        "sq": "Ende pa vendndodhje të ruajtura.",
        "zh-Hans": "暂无已保存地点。",
        "nl": "Nog geen opgeslagen locaties.",
    },
    "team_location_saved_empty_hint": {
        "en": "Save places you use often for faster scheduling.",
        "es": "Guarda lugares que usas a menudo para programar más rápido.",
        "fr": "Enregistrez les lieux que vous utilisez souvent pour planifier plus vite.",
        "pt": "Salve lugares que você usa com frequência para agendar mais rápido.",
        "de": "Speichere Orte, die du oft nutzt, für schnellere Planung.",
        "it": "Salva i luoghi che usi spesso per programmare più in fretta.",
        "pl": "Zapisz miejsca, których często używasz, by szybciej planować.",
        "ru": "Сохраняйте часто используемые места для быстрого планирования.",
        "sq": "Ruani vendet që përdorni shpesh për planifikim më të shpejtë.",
        "zh-Hans": "保存常用地点，安排日程更快。",
        "nl": "Sla plekken die je vaak gebruikt op voor sneller plannen.",
    },
    "team_location_saved_empty_tip": {
        "en": "Tip: tap ☆ on a recent place to save it.",
        "es": "Consejo: toca ☆ en un lugar reciente para guardarlo.",
        "fr": "Astuce : touchez ☆ sur un lieu récent pour l’enregistrer.",
        "pt": "Dica: toque em ☆ em um local recente para salvá-lo.",
        "de": "Tipp: Tippe auf ☆ bei einem kürzlichen Ort, um ihn zu speichern.",
        "it": "Suggerimento: tocca ☆ su un luogo recente per salvarlo.",
        "pl": "Wskazówka: stuknij ☆ przy niedawnym miejscu, aby je zapisać.",
        "ru": "Подсказка: нажмите ☆ у недавнего места, чтобы сохранить.",
        "sq": "Këshillë: prek ☆ te një vend i fundit për ta ruajtur.",
        "zh-Hans": "提示：点最近地点旁的 ☆ 即可保存。",
        "nl": "Tip: tik op ☆ bij een recente plek om die op te slaan.",
    },
    "team_location_save_action": {
        "en": "Save location",
        "es": "Guardar ubicación",
        "fr": "Enregistrer le lieu",
        "pt": "Salvar local",
        "de": "Ort speichern",
        "it": "Salva luogo",
        "pl": "Zapisz lokalizację",
        "ru": "Сохранить место",
        "sq": "Ruaj vendndodhjen",
        "zh-Hans": "保存地点",
        "nl": "Locatie opslaan",
    },
    "team_location_unsave_action": {
        "en": "Remove from Saved",
        "es": "Quitar de Guardadas",
        "fr": "Retirer des enregistrés",
        "pt": "Remover dos Salvos",
        "de": "Aus Gespeicherten entfernen",
        "it": "Rimuovi dai Salvati",
        "pl": "Usuń z Zapisanych",
        "ru": "Убрать из сохранённых",
        "sq": "Hiq nga të Ruajturat",
        "zh-Hans": "从已保存中移除",
        "nl": "Verwijderen uit Opgeslagen",
    },
    "team_location_save_a11y_hint": {
        "en": "Adds this place to Saved Locations for this Team.",
        "es": "Añade este lugar a Ubicaciones guardadas de este equipo.",
        "fr": "Ajoute ce lieu aux lieux enregistrés de cette équipe.",
        "pt": "Adiciona este local aos Locais salvos desta equipe.",
        "de": "Fügt diesen Ort zu den gespeicherten Orten dieses Teams hinzu.",
        "it": "Aggiunge questo luogo ai Luoghi salvati di questa squadra.",
        "pl": "Dodaje to miejsce do Zapisanych lokalizacji tej drużyny.",
        "ru": "Добавляет это место в сохранённые для этой команды.",
        "sq": "E shton këtë vend te Vendndodhjet e Ruajtura për këtë ekip.",
        "zh-Hans": "将此地点加入本队伍的已保存地点。",
        "nl": "Voegt deze plek toe aan Opgeslagen locaties voor dit team.",
    },
    "team_location_unsave_a11y_hint": {
        "en": "Removes this place from Saved Locations. Past events keep their location.",
        "es": "Quita este lugar de Guardadas. Los eventos pasados conservan su ubicación.",
        "fr": "Retire ce lieu des enregistrés. Les événements passés gardent leur lieu.",
        "pt": "Remove este local dos Salvos. Eventos passados mantêm o local.",
        "de": "Entfernt diesen Ort aus Gespeicherten. Vergangene Events behalten ihren Ort.",
        "it": "Rimuove questo luogo dai Salvati. Gli eventi passati mantengono il luogo.",
        "pl": "Usuwa to miejsce z Zapisanych. Minione wydarzenia zachowują lokalizację.",
        "ru": "Убирает место из сохранённых. Прошлые события сохраняют своё место.",
        "sq": "E heq këtë vend nga të Ruajturat. Ngjarjet e kaluara mbajnë vendndodhjen.",
        "zh-Hans": "从已保存中移除。过往活动仍保留其地点。",
        "nl": "Verwijdert deze plek uit Opgeslagen. Eerdere events behouden hun locatie.",
    },
    "team_location_save_prompt_title": {
        "en": "Save this location?",
        "es": "¿Guardar esta ubicación?",
        "fr": "Enregistrer ce lieu ?",
        "pt": "Salvar este local?",
        "de": "Diesen Ort speichern?",
        "it": "Salvare questo luogo?",
        "pl": "Zapisać tę lokalizację?",
        "ru": "Сохранить это место?",
        "sq": "Të ruhet kjo vendndodhje?",
        "zh-Hans": "保存此地点？",
        "nl": "Deze locatie opslaan?",
    },
    "team_location_save_prompt_body": {
        "en": "Saved locations stay available for this Team. You can also use it once without saving.",
        "es": "Las ubicaciones guardadas quedan disponibles para este equipo. También puedes usarla una vez sin guardar.",
        "fr": "Les lieux enregistrés restent disponibles pour cette équipe. Vous pouvez aussi l’utiliser une fois sans enregistrer.",
        "pt": "Locais salvos ficam disponíveis para esta equipe. Você também pode usar uma vez sem salvar.",
        "de": "Gespeicherte Orte bleiben für dieses Team verfügbar. Du kannst ihn auch einmal ohne Speichern nutzen.",
        "it": "I luoghi salvati restano disponibili per questa squadra. Puoi anche usarlo una volta senza salvare.",
        "pl": "Zapisane lokalizacje pozostają dostępne dla tej drużyny. Możesz też użyć raz bez zapisywania.",
        "ru": "Сохранённые места остаются доступны этой команде. Можно использовать один раз без сохранения.",
        "sq": "Vendndodhjet e ruajtura mbeten të disponueshme për këtë ekip. Mund ta përdorni edhe një herë pa e ruajtur.",
        "zh-Hans": "已保存地点会保留给本队伍使用。也可不保存直接使用一次。",
        "nl": "Opgeslagen locaties blijven beschikbaar voor dit team. Je kunt hem ook één keer gebruiken zonder op te slaan.",
    },
}


def main() -> None:
    data = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    strings = data.setdefault("strings", {})
    for key, translations in ENTRIES.items():
        entry = strings.setdefault(key, {})
        entry["extractionState"] = "manual"
        entry["localizations"] = locs(translations)
    XCSTRINGS.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Patched {len(ENTRIES)} keys into {XCSTRINGS}")


if __name__ == "__main__":
    main()
