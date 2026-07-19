#!/usr/bin/env python3
"""Regression checks for public-profile mutual-friend count format contracts.

Ensures Int/%lld overflow labels never use %@ (the DemoJT crash class).
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
XCSTRINGS = ROOT / "GameOn" / "Localizable.xcstrings"
SUPPORTED = ["en", "es", "fr", "pt", "de", "it", "pl", "ru", "sq", "zh-Hans"]

INT_KEYS = {
    "public_profile_more_mutual_friends_a11y_format",
    "public_profile_more_mutual_friend_a11y_format",
    "public_profile_mutual_fans_other",
    "public_profile_shared_teams_other",
}

OBJECT_KEYS = {
    "public_profile_open_mutual_friend_a11y_format",
    "public_profile_more_actions_a11y_format",
    "public_profile_poke_a11y_format",
}


def placeholders(value: str) -> list[str]:
    return re.findall(r"%(?:\d+\$)?[@lldiu]|%@", value) or re.findall(r"%[@a-z]+", value)


def main() -> int:
    data = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    strings = data.get("strings") or {}
    failures: list[str] = []

    for key in sorted(INT_KEYS | OBJECT_KEYS | {"public_profile_more"}):
        if key not in strings:
            failures.append(f"missing_key={key}")
            continue
        locs = strings[key].get("localizations") or {}
        for lang in SUPPORTED:
            if lang not in locs:
                failures.append(f"missing_locale key={key} lang={lang}")
                continue
            value = locs[lang]["stringUnit"]["value"]
            if key in INT_KEYS:
                if "%@" in value:
                    failures.append(f"int_key_has_object_placeholder key={key} lang={lang} value={value!r}")
                if "%lld" not in value and "%d" not in value:
                    failures.append(f"int_key_missing_numeric_placeholder key={key} lang={lang} value={value!r}")
                if "%d" in value and "%lld" not in value:
                    failures.append(f"int_key_uses_%d_not_%lld key={key} lang={lang} value={value!r}")
            if key in OBJECT_KEYS and "%lld" in value:
                failures.append(f"object_key_has_lld key={key} lang={lang} value={value!r}")

    # Simulate overflow formatting for counts used by DemoJT-style empty-avatar overflow.
    en_plural = strings["public_profile_more_mutual_friends_a11y_format"]["localizations"]["en"][
        "stringUnit"
    ]["value"]
    en_singular = strings["public_profile_more_mutual_friend_a11y_format"]["localizations"]["en"][
        "stringUnit"
    ]["value"]
    for count, fmt in [(1, en_singular), (2, en_plural), (10, en_plural)]:
        py_fmt = fmt.replace("%lld", "%d")
        try:
            rendered = py_fmt % count
        except Exception as exc:  # pragma: no cover
            failures.append(f"python_format_failed count={count} err={exc}")
            continue
        if str(count) not in rendered:
            failures.append(f"rendered_missing_count count={count} rendered={rendered!r}")

    if failures:
        print("public_profile_format_contracts=FAILED")
        for item in failures:
            print(f"  {item}")
        return 1

    print("public_profile_format_contracts=PASSED")
    print(f"int_keys={len(INT_KEYS)} object_keys={len(OBJECT_KEYS)} locales={len(SUPPORTED)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
