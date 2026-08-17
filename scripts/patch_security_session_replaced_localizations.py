#!/usr/bin/env python3
"""Localization for single-session security notifications."""
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
    "security_session_replaced_badge": {
        "en": "SECURITY",
        "es": "SEGURIDAD",
        "fr": "SÉCURITÉ",
        "pt": "SEGURANÇA",
        "de": "SICHERHEIT",
        "it": "SICUREZZA",
        "pl": "BEZPIECZEŃSTWO",
        "ru": "БЕЗОПАСНОСТЬ",
        "sq": "SIGURI",
        "zh-Hans": "安全",
        "nl": "BEVEILIGING",
    },
    "security_session_replaced_title": {
        "en": "New sign-in detected",
        "es": "Nuevo inicio de sesión detectado",
        "fr": "Nouvelle connexion détectée",
        "pt": "Novo início de sessão detectado",
        "de": "Neue Anmeldung erkannt",
        "it": "Nuovo accesso rilevato",
        "pl": "Wykryto nowe logowanie",
        "ru": "Обнаружен новый вход",
        "sq": "U zbulua një hyrje e re",
        "zh-Hans": "检测到新的登录",
        "nl": "Nieuwe aanmelding gedetecteerd",
    },
    "security_session_replaced_body": {
        "en": "Your FanGeo account was signed in on another device. This device has been signed out.",
        "es": "Tu cuenta de FanGeo se inició en otro dispositivo. Este dispositivo se ha cerrado.",
        "fr": "Votre compte FanGeo a été connecté sur un autre appareil. Cet appareil a été déconnecté.",
        "pt": "Sua conta FanGeo foi acessada em outro dispositivo. Este dispositivo foi desconectado.",
        "de": "Dein FanGeo-Konto wurde auf einem anderen Gerät angemeldet. Dieses Gerät wurde abgemeldet.",
        "it": "Il tuo account FanGeo è stato usato su un altro dispositivo. Questo dispositivo è stato disconnesso.",
        "pl": "Twoje konto FanGeo zalogowano na innym urządzeniu. To urządzenie zostało wylogowane.",
        "ru": "В ваш аккаунт FanGeo вошли с другого устройства. Это устройство вышло из системы.",
        "sq": "Llogaria jote FanGeo u hap në një pajisje tjetër. Kjo pajisje u shkëput.",
        "zh-Hans": "你的 FanGeo 账号已在另一台设备上登录。此设备已退出。",
        "nl": "Je FanGeo-account is aangemeld op een ander apparaat. Dit apparaat is uitgelogd.",
    },
    "security_session_replaced_device_format": {
        "en": "Signed in on %@",
        "es": "Inicio de sesión en %@",
        "fr": "Connexion sur %@",
        "pt": "Sessão iniciada no %@",
        "de": "Angemeldet auf %@",
        "it": "Accesso su %@",
        "pl": "Zalogowano na urządzeniu %@",
        "ru": "Вход выполнен на %@",
        "sq": "Hyrë në %@",
        "zh-Hans": "已在%@上登录",
        "nl": "Aangemeld op %@",
    },
    "security_session_replaced_signed_out_notice": {
        "en": "You were signed out because your account was opened on another device.",
        "es": "Se cerró tu sesión porque tu cuenta se abrió en otro dispositivo.",
        "fr": "Vous avez été déconnecté car votre compte a été ouvert sur un autre appareil.",
        "pt": "Você foi desconectado porque sua conta foi aberta em outro dispositivo.",
        "de": "Du wurdest abgemeldet, weil dein Konto auf einem anderen Gerät geöffnet wurde.",
        "it": "Sei stato disconnesso perché il tuo account è stato aperto su un altro dispositivo.",
        "pl": "Wylogowano Cię, ponieważ konto otwarto na innym urządzeniu.",
        "ru": "Вы вышли из системы, потому что аккаунт открыли на другом устройстве.",
        "sq": "U shkëpute sepse llogaria u hap në një pajisje tjetër.",
        "zh-Hans": "你已退出，因为账号在另一台设备上登录。",
        "nl": "Je bent uitgelogd omdat je account op een ander apparaat is geopend.",
    },
    "security_session_replaced_cta": {
        "en": "View details",
        "es": "Ver detalles",
        "fr": "Voir les détails",
        "pt": "Ver detalhes",
        "de": "Details anzeigen",
        "it": "Vedi dettagli",
        "pl": "Zobacz szczegóły",
        "ru": "Подробнее",
        "sq": "Shiko detajet",
        "zh-Hans": "查看详情",
        "nl": "Bekijk details",
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
