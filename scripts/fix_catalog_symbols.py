#!/usr/bin/env python3
"""Disable String Catalog symbol generation for keys that break GenerateStringSymbols."""
from __future__ import annotations

import json
import re
from pathlib import Path

XCSTRINGS = Path(__file__).resolve().parents[1] / "GameOn" / "Localizable.xcstrings"

INVALID_SYMBOL = re.compile(r"^[^A-Za-z_].*$|^[0-9].*$")
SEMANTIC = re.compile(r"^[a-z][a-z0-9_]*$")


def symbol_base(key: str) -> str:
    # Mirror Xcode: lowercased alnum chunks joined by underscore
    parts = re.findall(r"[A-Za-z0-9]+", key)
    return "_".join(p.lower() for p in parts if p)


def main() -> None:
    data = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    strings = data["strings"]

    bases: dict[str, list[str]] = {}
    for key in strings:
        if not key.strip():
            continue
        bases.setdefault(symbol_base(key), []).append(key)

    disabled = 0
    for key, entry in strings.items():
        if not key.strip():
            continue
        disable = False
        if INVALID_SYMBOL.match(key):
            disable = True
        elif len(bases.get(symbol_base(key), [])) > 1:
            disable = True
        if disable:
            entry["generateSymbol"] = False
            disabled += 1

    XCSTRINGS.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Disabled symbol generation for {disabled} keys")


if __name__ == "__main__":
    main()
