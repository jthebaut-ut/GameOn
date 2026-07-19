#!/usr/bin/env python3
"""Validate GameOn/Localizable.xcstrings against literal Swift L10n keys.

Fails when:
- literal L10n.t("...") keys are missing from the catalog
- a supported locale disappears from the catalog entirely
- catalog entry count is suspiciously small versus a baseline snapshot

Does not attempt to validate dynamically constructed keys.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
XCSTRINGS = ROOT / "GameOn" / "Localizable.xcstrings"
SUPPORTED = ["en", "es", "fr", "pt", "de", "it", "pl", "ru", "sq", "zh-Hans"]
# Soft floor after emergency recovery; raise over time as catalog grows.
MIN_CATALOG_ENTRIES = 3000


def literal_l10n_keys() -> set[str]:
    pat = re.compile(r'L10n\.t\(\s*"([^"\\]+)"')
    keys: set[str] = set()
    for path in (ROOT / "GameOn").rglob("*.swift"):
        text = path.read_text(encoding="utf-8", errors="ignore")
        keys.update(pat.findall(text))
    return keys


def locale_present(strings: dict, lang: str) -> bool:
    for entry in strings.values():
        locs = entry.get("localizations") or {}
        try:
            val = locs[lang]["stringUnit"]["value"]
        except Exception:
            continue
        if isinstance(val, str) and val.strip():
            return True
    return False


def main() -> int:
    data = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    strings = data.get("strings") or {}
    keys = literal_l10n_keys()
    missing = sorted(k for k in keys if k not in strings)
    missing_locales = [lang for lang in SUPPORTED if not locale_present(strings, lang)]

    print(f"catalog_entries={len(strings)}")
    print(f"literal_l10n_keys={len(keys)}")
    print(f"literal_missing={len(missing)}")
    if missing:
        print("missing_keys:")
        for key in missing:
            print(f"  {key}")
    if missing_locales:
        print("missing_locales:", ", ".join(missing_locales))
    if len(strings) < MIN_CATALOG_ENTRIES:
        print(
            f"catalog_too_small: {len(strings)} < minimum {MIN_CATALOG_ENTRIES}",
            file=sys.stderr,
        )
        return 1
    if missing_locales:
        return 1
    if missing:
        return 1
    print("localization_validation=PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
