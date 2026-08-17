#!/usr/bin/env python3
"""Rebuild catalog-identities.ts from FanGeo Swift catalogs.

Aliases are taken only from the same Swift call that declares the identity.
College picker rows are skipped. FanGeo user-created Teams are never included.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).with_name("catalog-identities.ts")

SPORT_LABEL = {
    "soccer": "Soccer",
    "basketball": "Basketball",
    "football": "Football",
    "baseball": "Baseball",
    "hockey": "Hockey",
    "tennis": "Tennis",
    "golf": "Golf",
    "badminton": "Badminton",
    "cricket": "Cricket",
    "rugby": "Rugby",
    "ncaa": "NCAA",
    "olympics": "Olympics",
    "racing": "Racing",
    "combat": "Combat",
    "dance": "Dance",
}

KIND_LABEL = {
    "team": "team",
    "nationalTeam": "national_team",
    "player": "player",
    "league": "league",
    "competition": "league",
    "tournament": "league",
}

SKIP_KINDS = {"interest"}
PRO_REGIONS = {"NBA", "WNBA", "MLB", "NHL", "NFL"}


def extract_balanced(source: str, start: int) -> str:
    depth = 0
    in_string = False
    escape = False
    for index in range(start, len(source)):
        char = source[index]
        if in_string:
            if escape:
                escape = False
            elif char == "\\":
                escape = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
            continue
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return source[start : index + 1]
    raise ValueError("unbalanced call")


def parse_string_list(raw: str) -> list[str]:
    return re.findall(r'"((?:\\.|[^"\\])*)"', raw)


def unescape(value: str) -> str:
    return bytes(value, "utf-8").decode("unicode_escape") if "\\" in value else value


def parse_aliases(call: str) -> list[str]:
    match = re.search(r"aliases:\s*\[(.*?)\]", call, re.S)
    if not match:
        return []
    return [unescape(item) for item in parse_string_list(match.group(1))]


def parse_kind(call: str) -> str:
    match = re.search(r"kind:\s*\.(\w+)", call)
    return match.group(1) if match else "team"


def parse_short_code(call: str) -> str | None:
    match = re.search(r"shortCode:\s*\"((?:\\.|[^\"\\])*)\"", call)
    if match:
        return unescape(match.group(1))
    match = re.search(r"short:\s*\"((?:\\.|[^\"\\])*)\"", call)
    if match:
        return unescape(match.group(1))
    return None


def add_identity(
    rows: dict[str, dict],
    catalog_id: str,
    name: str,
    sport: str,
    league: str,
    kind: str,
    aliases: list[str],
) -> None:
    if kind in SKIP_KINDS:
        return
    mapped_kind = KIND_LABEL.get(kind)
    if mapped_kind is None:
        return
    sport_label = SPORT_LABEL.get(sport, sport.title())
    unique_aliases: list[str] = []
    seen = {name.casefold()}
    for alias in aliases:
        cleaned = alias.strip()
        if not cleaned or cleaned.casefold() in seen:
            continue
        seen.add(cleaned.casefold())
        unique_aliases.append(cleaned)
    incoming = {
        "catalogId": catalog_id,
        "name": name,
        "sport": sport_label,
        "league": league,
        "kind": mapped_kind,
        "aliases": unique_aliases,
    }
    existing = rows.get(catalog_id)
    if existing is None:
        rows[catalog_id] = incoming
        return
    merged = list(existing["aliases"])
    seen_aliases = {item.casefold() for item in merged}
    for alias in unique_aliases:
        if alias.casefold() not in seen_aliases:
            merged.append(alias)
            seen_aliases.add(alias.casefold())
    existing["aliases"] = merged


def harvest_named_calls(source: str, fn_name: str, rows: dict[str, dict]) -> None:
    for match in re.finditer(rf"\b{fn_name}\(", source):
        call = extract_balanced(source, match.start() + len(fn_name))
        strings = parse_string_list(call)
        sport_match = re.search(r"\.(soccer|basketball|football|baseball|hockey|tennis|golf|badminton|cricket|rugby|ncaa|olympics|racing|combat|dance)\b", call)
        if fn_name in {"team", "make"}:
            # team/make: id, name, .sport, league, symbol, ...
            if len(strings) < 3 or not sport_match:
                continue
            catalog_id, name, league = strings[0], strings[1], strings[2]
            sport = sport_match.group(1)
            kind = parse_kind(call)
            aliases = parse_aliases(call)
            short = parse_short_code(call)
            if short:
                aliases.append(short)
            add_identity(rows, catalog_id, name, sport, league, kind, aliases)
        elif fn_name == "wClub":
            if len(strings) < 5:
                continue
            catalog_id, name, league, _region, code = strings[:5]
            aliases = parse_string_list(call)[5:]
            aliases.append(code)
            add_identity(rows, catalog_id, name, "soccer", league, "team", aliases)
        elif fn_name == "wnt":
            if len(strings) < 3:
                continue
            catalog_id, name, code = strings[:3]
            aliases = parse_string_list(call)[3:]
            aliases.append(code)
            add_identity(rows, catalog_id, name, "soccer", "Women's National Team", "nationalTeam", aliases)
        elif fn_name == "league":
            if len(strings) < 3:
                continue
            catalog_id, name, code = strings[:3]
            aliases = parse_string_list(call)[3:]
            aliases.append(code)
            add_identity(rows, catalog_id, name, "soccer", "Soccer League", "league", aliases)
        elif fn_name == "country":
            if len(strings) < 4 or not sport_match:
                continue
            slug, name, region, group = strings[0], strings[1], strings[2], strings[3]
            sport = sport_match.group(1)
            catalog_id = f"{sport}-country-{slug}"
            aliases = []
            short = parse_short_code(call)
            if short:
                aliases.append(short)
            league = "National Team" if "national" in group.lower() else group
            add_identity(rows, catalog_id, name, sport, league, "nationalTeam", aliases)


def harvest_team_lists(source: str, rows: dict[str, dict]) -> None:
    pattern = re.compile(
        r"teamList\(\.(soccer|basketball|football|baseball|hockey),\s*\"([^\"]+)\",\s*\"([^\"]+)\",\s*icon:\s*\"[^\"]+\",\s*\[(.*?)\]\s*\)",
        re.S,
    )
    tuple_re = re.compile(r"\(\s*\"([^\"]+)\"\s*,\s*\"([^\"]+)\"\s*,\s*\"([^\"]+)\"\s*\)")
    for match in pattern.finditer(source):
        sport, region, group, body = match.groups()
        if "college" in region.lower() or "college" in group.lower():
            continue
        league = region if region in PRO_REGIONS else group
        for slug, name, short in tuple_re.findall(body):
            catalog_id = f"{sport}-team-{slug}"
            aliases = [short] if short else []
            slug_alias = slug.replace("-", " ")
            if len(slug_alias) >= 4:
                aliases.append(slug_alias)
            add_identity(rows, catalog_id, name, sport, league, "team", aliases)


def ts_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def render(rows: dict[str, dict]) -> str:
    lines = [
        "export type SportsCatalogKind = \"team\" | \"national_team\" | \"player\" | \"league\"",
        "",
        "export type SportsCatalogIdentity = {",
        "  catalogId: string",
        "  name: string",
        "  sport: string",
        "  league: string",
        "  kind: SportsCatalogKind",
        "  aliases: string[]",
        "}",
        "",
        "/** FanGeo professional catalog identities for server-side provider matching.",
        " * Generated from FavoriteTeamCatalog + SportsTeamPickerData.",
        " * Aliases belong only to the identity that declared them.",
        " */",
        "export const CATALOG_IDENTITIES: SportsCatalogIdentity[] = [",
    ]
    for item in rows.values():
        aliases = ", ".join(ts_string(alias) for alias in item["aliases"])
        lines.append(
            "  { "
            f"catalogId: {ts_string(item['catalogId'])}, "
            f"name: {ts_string(item['name'])}, "
            f"sport: {ts_string(item['sport'])}, "
            f"league: {ts_string(item['league'])}, "
            f"kind: {ts_string(item['kind'])}, "
            f"aliases: [{aliases}] "
            "},"
        )
    lines.append("]")
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    rows: dict[str, dict] = {}
    catalog_files = [
        ROOT / "GameOn/FavoriteTeamCatalog.swift",
        ROOT / "GameOn/FavoriteTeamCatalog+ExpandedEntities.swift",
        ROOT / "GameOn/FavoriteTeamCatalog+GlobalCoverage.swift",
    ]
    for path in catalog_files:
        source = path.read_text()
        for fn_name in ("team", "make", "wClub", "wnt", "league"):
            harvest_named_calls(source, fn_name, rows)
    picker = (ROOT / "GameOn/SportsTeamPickerData.swift").read_text()
    harvest_named_calls(picker, "country", rows)
    harvest_team_lists(picker, rows)
    OUT.write_text(render(rows))
    print(f"wrote {len(rows)} identities -> {OUT}")


if __name__ == "__main__":
    main()
