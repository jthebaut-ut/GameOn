#!/usr/bin/env python3
"""Validate FavoriteTeamCatalog expansion data without requiring an Xcode compile.

Parses Swift catalog sources for id/name/kind/sport patterns and checks:
- duplicate IDs
- empty names
- required expansion IDs present
- search alias coverage for key short codes

This is a lightweight structural check; Swift FavoriteCatalogValidation remains the
runtime source of truth inside the app.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CATALOG_FILES = [
    ROOT / "GameOn" / "FavoriteTeamCatalog.swift",
    ROOT / "GameOn" / "FavoriteTeamCatalog+ExpandedEntities.swift",
    ROOT / "GameOn" / "FavoriteTeamCatalog+GlobalCoverage.swift",
]

TEAM_RE = re.compile(
    r'(?:team|make|wnt|league|wClub)\(\s*"([^"]+)"\s*,\s*"([^"]+)"',
    re.MULTILINE,
)

REQUIRED_IDS = [
    "tournament-uefa-euro",
    "tournament-copa-america",
    "tournament-europa-league",
    "tournament-conference-league",
    "tournament-fifa-womens-world-cup",
    "tournament-uwcl",
    "league-nwsl",
    "league-wsl",
    "soccer-usa-women",
    "soccer-england-women",
    "league-efl-championship",
    "league-brasileirao",
    "tournament-world-baseball-classic",
    "tournament-super-bowl",
    "tournament-ipl",
    "tournament-rugby-world-cup",
    "tournament-motogp",
    "tournament-summer-olympics",
    "league-premier-league",
]


def main() -> int:
    text = "\n".join(path.read_text(encoding="utf-8") for path in CATALOG_FILES)
    rows = TEAM_RE.findall(text)
    # Optional sport capture from team/make forms
    sport_re = re.compile(
        r'(?:team|make)\(\s*"([^"]+)"\s*,\s*"([^"]+)"\s*,\s*\.(\w+)',
        re.MULTILINE,
    )
    ids = [r[0] for r in rows]
    names = {r[0]: r[1] for r in rows}
    sports = {r[0]: r[2] for r in sport_re.findall(text)}


    dupes = sorted({i for i in ids if ids.count(i) > 1})
    empty = sorted(i for i, n in names.items() if not n.strip())
    missing = [i for i in REQUIRED_IDS if i not in names]

    # Alias sanity: Premier League must advertise EPL nearby in source.
    pl_ok = 'aliases: ["EPL"' in text or '"EPL"' in text
    ucl_ok = '"UCL"' in text
    afcon_ok = '"AFCON"' in text
    wwc_ok = '"WWC"' in text

    print(f"parsed_entries={len(ids)}")
    print(f"unique_ids={len(set(ids))}")
    print(f"sports={sorted(set(sports.values()))}")
    if dupes:
        print("duplicate_ids:")
        for d in dupes:
            print(f"  {d}")
    if empty:
        print("empty_names:")
        for e in empty:
            print(f"  {e}")
    if missing:
        print("missing_required_ids:")
        for m in missing:
            print(f"  {m}")
    print(f"epl_alias_present={pl_ok}")
    print(f"ucl_alias_present={ucl_ok}")
    print(f"afcon_alias_present={afcon_ok}")
    print(f"wwc_alias_present={wwc_ok}")

    # Women's USA must be distinct from men's
    if "soccer-usa-women" in names and "soccer-usa" in names:
        print("womens_usa_separated=true")
    else:
        print("womens_usa_separated=false")

    usmnt_aliases = False
    # Ensure USWNT is not still aliased onto men's USA line
    for line in text.splitlines():
        if '"soccer-usa"' in line and "USWNT" in line:
            usmnt_aliases = True
    print(f"mens_usa_still_has_uswnt_alias={usmnt_aliases}")

    failed = bool(dupes or empty or missing or not pl_ok or usmnt_aliases)
    print("favorite_catalog_validation=" + ("FAILED" if failed else "PASSED"))
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
