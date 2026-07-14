#!/usr/bin/env python3
"""Generate ui_translations_bulk.json for English-as-key catalog entries."""
from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
XCSTRINGS = ROOT / "GameOn" / "Localizable.xcstrings"
OUT = Path(__file__).with_name("ui_translations_bulk.json")
SUPPORTED = ["en", "es", "fr", "pt", "de", "it", "pl", "ru", "sq", "zh-Hans"]
TARGETS = [l for l in SUPPORTED if l != "en"]

# Preserve product names and API tokens in all languages.
PRESERVE = ["FanGeo", "FanGeo+", "Business Pro", "Business Regular", "Discover", "Apple", "StoreKit", "iOS", "Face ID", "PRO"]


def protect(text: str) -> tuple[str, dict[str, str]]:
    tokens: dict[str, str] = {}
    out = text
    for i, token in enumerate(PRESERVE):
        if token in out:
            key = f"@@P{i}@@"
            tokens[key] = token
            out = out.replace(token, key)
    return out, tokens


def restore(text: str, tokens: dict[str, str]) -> str:
    for key, token in tokens.items():
        text = text.replace(key, token)
    return text


# Hand-translated high-priority UI strings (English key -> locale map without en).
HAND: dict[str, dict[str, str]] = {}


def load_hand_from_existing(data: dict) -> None:
    """Seed HAND from keys already fully translated in catalog."""
    for key, entry in data.get("strings", {}).items():
        locs = entry.get("localizations", {})
        if not key or len(key) < 2:
            continue
        if all(lang in locs for lang in SUPPORTED):
            HAND.setdefault(key, {})
            for lang in TARGETS:
                val = locs[lang]["stringUnit"]["value"]
                HAND[key][lang] = val


PHRASES: dict[str, dict[str, str]] = {
    "Cancel": {
        "es": "Cancelar", "fr": "Annuler", "pt": "Cancelar", "de": "Abbrechen",
        "it": "Annulla", "pl": "Anuluj", "ru": "Отмена", "sq": "Anulo", "zh-Hans": "取消",
    },
    "Done": {
        "es": "Listo", "fr": "Terminé", "pt": "Concluído", "de": "Fertig",
        "it": "Fine", "pl": "Gotowe", "ru": "Готово", "sq": "U krye", "zh-Hans": "完成",
    },
    "Active": {
        "es": "Activo", "fr": "Actif", "pt": "Ativo", "de": "Aktiv",
        "it": "Attivo", "pl": "Aktywny", "ru": "Активно", "sq": "Aktiv", "zh-Hans": "活跃",
    },
    "Regular": {
        "es": "Regular", "fr": "Regular", "pt": "Regular", "de": "Regular",
        "it": "Regular", "pl": "Regular", "ru": "Regular", "sq": "Regular", "zh-Hans": "Regular",
    },
    "Loading business data…": {
        "es": "Cargando datos del negocio…", "fr": "Chargement des données professionnelles…",
        "pt": "Carregando dados do negócio…", "de": "Geschäftsdaten werden geladen…",
        "it": "Caricamento dati business…", "pl": "Ładowanie danych firmy…",
        "ru": "Загрузка бизнес-данных…", "sq": "Duke ngarkuar të dhënat e biznesit…", "zh-Hans": "正在加载企业数据…",
    },
    "Add a Venue": {
        "es": "Agregar un local", "fr": "Ajouter un lieu", "pt": "Adicionar um local",
        "de": "Standort hinzufügen", "it": "Aggiungi un locale", "pl": "Dodaj miejsce",
        "ru": "Добавить площадку", "sq": "Shto një vend", "zh-Hans": "添加场馆",
    },
    "Limit reached": {
        "es": "Límite alcanzado", "fr": "Limite atteinte", "pt": "Limite atingido",
        "de": "Limit erreicht", "it": "Limite raggiunto", "pl": "Osiągnięto limit",
        "ru": "Лимит достигнут", "sq": "Kufiri u arrit", "zh-Hans": "已达上限",
    },
    "Contact Support": {
        "es": "Contactar soporte", "fr": "Contacter le support", "pt": "Contatar suporte",
        "de": "Support kontaktieren", "it": "Contatta il supporto", "pl": "Skontaktuj się z pomocą",
        "ru": "Связаться с поддержкой", "sq": "Kontakto mbështetjen", "zh-Hans": "联系支持",
    },
    "Business account deleted.": {
        "es": "Cuenta empresarial eliminada.", "fr": "Compte professionnel supprimé.",
        "pt": "Conta empresarial excluída.", "de": "Business-Konto gelöscht.",
        "it": "Account business eliminato.", "pl": "Konto firmowe usunięte.",
        "ru": "Бизнес-аккаунт удалён.", "sq": "Llogaria e biznesit u fshi.", "zh-Hans": "企业账户已删除。",
    },
    "You have been signed out.": {
        "es": "Has cerrado sesión.", "fr": "Vous avez été déconnecté.",
        "pt": "Você saiu da conta.", "de": "Sie wurden abgemeldet.",
        "it": "Hai effettuato l’uscita.", "pl": "Wylogowano Cię.",
        "ru": "Вы вышли из аккаунта.", "sq": "Jeni çkyçur.", "zh-Hans": "您已退出登录。",
    },
}


def translate_key(en: str, lang: str) -> str | None:
    if en in HAND and lang in HAND[en]:
        return HAND[en][lang]
    if en in PHRASES and lang in PHRASES[en]:
        return PHRASES[en][lang]
    return None


def is_ui_key(key: str) -> bool:
    if not key or len(key.strip()) < 2:
        return False
    if re.fullmatch(r"[\s\W\d]+", key):
        return False
    if key in {"@alexmorgan", "@fangeosports", "you@email.com"}:
        return False
    if "\\(" in key and "%" not in key and "@" not in key:
        return False
    return True


def main() -> None:
    data = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    load_hand_from_existing(data)

    bulk: dict[str, dict[str, str]] = {}
    missing_total = 0
    filled_total = 0
    unfilled: list[str] = []

    for key, entry in data.get("strings", {}).items():
        if not is_ui_key(key):
            continue
        locs = entry.get("localizations", {})
        missing_langs = [lang for lang in SUPPORTED if lang not in locs]
        if not missing_langs:
            continue
        missing_total += 1
        values: dict[str, str] = {"en": key}
        for lang in missing_langs:
            if lang == "en":
                values[lang] = key
                continue
            translated = translate_key(key, lang)
            if translated:
                values[lang] = translated
                filled_total += 1
        if any(lang in values for lang in TARGETS):
            bulk[key] = values
        else:
            unfilled.append(key)

    OUT.write_text(json.dumps(bulk, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Keys needing work: {missing_total}")
    print(f"Locale fills from HAND/PHRASES: {filled_total}")
    print(f"Bulk entries written: {len(bulk)}")
    print(f"Still unfilled keys: {len(unfilled)}")


if __name__ == "__main__":
    main()
