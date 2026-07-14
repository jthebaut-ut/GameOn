#!/usr/bin/env python3
"""Merge hand-translation chunks into ui_hand_translations.json."""
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CHUNK_DIR = ROOT / "_hand_chunks"
OUT = ROOT / "ui_hand_translations.json"
STRINGS_FILE = Path("/tmp/strings_to_translate.txt")
LOCALES = ["es", "fr", "pt", "de", "it", "pl", "ru", "sq", "zh-Hans"]


def main() -> None:
    strings = STRINGS_FILE.read_text(encoding="utf-8").splitlines()
    merged: dict[str, dict[str, str]] = {}

    for path in sorted(CHUNK_DIR.glob("chunk_*.json")):
        chunk = json.loads(path.read_text(encoding="utf-8"))
        merged.update(chunk)

    missing = [s for s in strings if s not in merged]
    incomplete = [
        s for s in strings
        if s in merged and any(loc not in merged[s] for loc in LOCALES)
    ]

    if missing:
        raise SystemExit(f"Missing {len(missing)} keys. First: {missing[:5]}")
    if incomplete:
        raise SystemExit(f"Incomplete {len(incomplete)} keys. First: {incomplete[:5]}")

    ordered = {s: merged[s] for s in strings}
    OUT.write_text(json.dumps(ordered, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {len(ordered)} keys to {OUT}")


if __name__ == "__main__":
    main()
