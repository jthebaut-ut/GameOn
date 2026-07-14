#!/usr/bin/env python3
"""Shared runtime for generating hand translation chunks."""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

VENDOR = Path(__file__).resolve().parents[1] / ".vendor"
if VENDOR.exists():
    sys.path.insert(0, str(VENDOR))

try:
    from deep_translator import GoogleTranslator
except Exception as exc:  # pragma: no cover - runtime dependency check
    raise SystemExit(
        "deep-translator is required. Install with: pip3 install deep-translator"
    ) from exc


BASE_DIR = Path(__file__).resolve().parent
STRINGS_FILE = Path("/tmp/strings_to_translate.txt")
LOCALES = ["es", "fr", "pt", "de", "it", "pl", "ru", "sq", "zh-Hans"]
TARGETS = {
    "es": "es",
    "fr": "fr",
    "pt": "pt",
    "de": "de",
    "it": "it",
    "pl": "pl",
    "ru": "ru",
    "sq": "sq",
    "zh-Hans": "zh-CN",
}

# Keep product names and tokens untouched.
PRESERVE = [
    "FanGeo",
    "FanGeo+",
    "Business Pro",
    "Business Regular",
    "Discover",
    "Apple",
    "PRO",
    "LIVE",
    "VS",
]

# Enforce requested terminology in translated outputs.
TERM_NORMALIZE = {
    "es": {
        r"\blugar(?:es)?\b": "local",
        r"\bnegocio(?:s)?\b": "negocio",
        r"\bsoporte\b": "soporte",
    },
    "fr": {
        r"\bendroit(?:s)?\b": "lieu",
        r"\bentreprise(?:s)?\b": "entreprise",
        r"\bassistance\b": "support",
    },
    "pt": {
        r"\blugar(?:es)?\b": "local",
        r"\bnegócio(?:s)?\b": "negócio",
        r"\bsuporte\b": "suporte",
    },
    "de": {
        r"\bOrt(?:e)?\b": "Standort",
        r"\bGeschäft(?:e)?\b": "Geschäft",
        r"\bUnterstützung\b": "Support",
    },
    "it": {
        r"\bluogo(?:hi)?\b": "locale",
        r"\battività\b": "business",
        r"\bassistenza\b": "supporto",
    },
    "pl": {
        r"\blokalizacja(?:e|i)?\b": "miejsce",
        r"\bfirma(?:y)?\b": "firma",
        r"\bwsparcie\b": "wsparcie",
    },
    "ru": {
        r"\bместо\b": "площадка",
        r"\bбизнес\b": "бизнес",
        r"\bподдержка\b": "поддержка",
    },
    "sq": {
        r"\bvend(?:e)?\b": "vendi",
        r"\bbiznes(?:e)?\b": "biznes",
        r"\bmbështetje\b": "mbështetje",
    },
    "zh-Hans": {
        "地点": "场馆",
        "企业": "企业",
        "支持": "支持",
    },
}


def _protect_tokens(text: str) -> tuple[str, dict[str, str]]:
    out = text
    repl: dict[str, str] = {}
    for idx, token in enumerate(PRESERVE):
        if token in out:
            marker = f"@@P{idx}@@"
            repl[marker] = token
            out = out.replace(token, marker)
    return out, repl


def _restore_tokens(text: str, repl: dict[str, str]) -> str:
    out = text
    for marker, token in repl.items():
        out = out.replace(marker, token)
    return out


def _normalize_terms(text: str, locale: str) -> str:
    normalized = text
    for pattern, replacement in TERM_NORMALIZE.get(locale, {}).items():
        normalized = re.sub(pattern, replacement, normalized, flags=re.IGNORECASE)
    return normalized


def _translate_value(text: str, locale: str) -> str:
    if not text:
        return text

    protected, repl = _protect_tokens(text)
    target = TARGETS[locale]
    try:
        translated = GoogleTranslator(source="en", target=target).translate(protected)
    except Exception:
        translated = protected
    translated = translated if isinstance(translated, str) and translated else protected
    translated = _restore_tokens(translated, repl)
    translated = _normalize_terms(translated, locale)
    return translated


def _load_strings() -> list[str]:
    values = STRINGS_FILE.read_text(encoding="utf-8").splitlines()
    if len(values) != 565:
        raise SystemExit(f"Expected 565 strings, found {len(values)}")
    return values


def write_chunk(chunk_num: int, start_idx: int, end_idx: int) -> None:
    """
    Write chunk JSON for 1-based inclusive string indexes.
    Example: start_idx=51, end_idx=97.
    """
    strings = _load_strings()
    selected = strings[start_idx - 1 : end_idx]
    if not selected:
        raise SystemExit("No strings selected for this chunk range")

    payload: dict[str, dict[str, str]] = {}
    for key in selected:
        payload[key] = {}
        for locale in LOCALES:
            payload[key][locale] = _translate_value(key, locale)

    out_path = BASE_DIR / f"chunk_{chunk_num:02d}.json"
    out_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Wrote {len(payload)} keys to {out_path}")
