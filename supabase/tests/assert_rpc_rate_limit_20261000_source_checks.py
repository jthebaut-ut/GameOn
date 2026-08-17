#!/usr/bin/env python3
"""Source checks for 20261000 rate-limit merge. Does not apply SQL.

Must FAIL if 20261000 still contains a static full-function reconstruction of
public.assert_rpc_rate_limit. The Team-discovery migration may only patch the
live pg_get_functiondef ARRAY initializer.

Must also FAIL if COMMIT; appears before the final postflight verification,
or if a correctness DO block remains after COMMIT.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATIONS = ROOT / "supabase" / "migrations"
TARGET = MIGRATIONS / "20261000_0001_fan_team_discoverability.sql"

PERFORM_RE = re.compile(
    r"""PERFORM\s+public\.assert_rpc_rate_limit\(\s*'([a-z][a-z0-9_]*)'""",
    re.IGNORECASE,
)
REPO_ARRAY_RE = re.compile(
    r"v_repo text\[\] := ARRAY\[(.*?)\]",
    re.DOTALL,
)
BUCKET_LIT_RE = re.compile(r"'([a-z][a-z0-9_]*)'")

# Recognizable hard-coded limiter implementation fragments. These may appear
# only if the migration is inspecting live-definition text (e.g. searching a
# variable that holds pg_get_functiondef output). Reproducing them as a
# replacement template is forbidden.
HARD_CODED_LIMITER_FRAGMENTS = (
    "INSERT INTO public.rpc_rate_limits",
    "rate_limit_exceeded",
    "random() < 0.01",
    "DELETE FROM public.rpc_rate_limits",
    "CREATE OR REPLACE FUNCTION public.assert_rpc_rate_limit",
    "me uuid := auth.uid()",
    "ON CONFLICT (actor_uid, bucket, window_start)",
    "SET search_path = public",
    "RETURNS void",
    "LANGUAGE plpgsql",
    "EXECUTE format(",
    "$fn$",
    "$body$",
)


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


def perform_buckets() -> set[str]:
    found: set[str] = set()
    for path in sorted(MIGRATIONS.glob("*.sql")):
        text = path.read_text(encoding="utf-8")
        for match in PERFORM_RE.finditer(text):
            found.add(match.group(1))
    return found


def repo_contract(sql: str) -> set[str]:
    match = REPO_ARRAY_RE.search(sql)
    if not match:
        fail("20261000 missing v_repo text[] := ARRAY[...] contract")
    return set(BUCKET_LIT_RE.findall(match.group(1)))


def rate_limit_section(sql: str) -> str:
    start = sql.find("-- 2) Rate-limit")
    end = sql.find("-- 3) Helpers")
    if start < 0 or end < 0 or end <= start:
        fail("20261000 missing Rate-limit / Helpers section markers")
    return sql[start:end]


COMMIT_RE = re.compile(r"(?m)^COMMIT\s*;\s*$")
BEGIN_RE = re.compile(r"(?m)^BEGIN\s*;\s*$")


CANONICAL_RL_ARRAY_INIT = (
    r"v_allowed_buckets[[:space:]]+text[[:space:]]*\[\][[:space:]]*:="
    r"[[:space:]]*ARRAY\[(?:.|\n)*?\][[:space:]]*(::[[:space:]]*text\[\])?[[:space:]]*;"
)
CANONICAL_RL_ARRAY_CAPTURE = (
    r"(v_allowed_buckets[[:space:]]+text[[:space:]]*\[\][[:space:]]*:="
    r"[[:space:]]*ARRAY\[)((?:.|\n)*?)(\][[:space:]]*(::[[:space:]]*text\[\])?[[:space:]]*;)"
)
NARROW_ARRAY_PARSER = (
    r"v_allowed_buckets[[:space:]]+text\[\][[:space:]]*:="
    r"[[:space:]]*ARRAY\[((?:.|\n)*?)\][[:space:]]*;"
)


def posix_to_python(pattern: str) -> str:
    return pattern.replace("[[:space:]]", r"\s")


def assert_canonical_array_parser(sql: str, checks_sql: str) -> None:
    """Every 20261000 rate-limit parser must accept optional ::text[]."""
    init_count = sql.count(CANONICAL_RL_ARRAY_INIT)
    capture_count = sql.count(CANONICAL_RL_ARRAY_CAPTURE)
    if init_count < 2:
        fail(
            "canonical ARRAY init parser must be reused in live merge and "
            f"final postflight (found {init_count})"
        )
    if capture_count < 2:
        fail(
            "canonical ARRAY capture parser must be reused in live merge and "
            f"final postflight (found {capture_count})"
        )
    if sql.count("CANONICAL_RL_ARRAY_INIT_PATTERN (do not fork)") < 2:
        fail("canonical init parser label missing from merge or postflight")
    if sql.count("CANONICAL_RL_ARRAY_CAPTURE_PATTERN (do not fork)") < 2:
        fail("canonical capture parser label missing from merge or postflight")

    if NARROW_ARRAY_PARSER in sql:
        fail("final postflight still uses the narrow ARRAY parser that rejects ::text[]")
    if NARROW_ARRAY_PARSER in checks_sql:
        fail("catalog checks still use the narrow ARRAY parser that rejects ::text[]")

    require(checks_sql, CANONICAL_RL_ARRAY_CAPTURE, "catalog checks must use the canonical capture parser")
    require(checks_sql, CANONICAL_RL_ARRAY_INIT, "catalog checks must use the canonical init parser")

    py_init = re.compile(posix_to_python(CANONICAL_RL_ARRAY_INIT))
    py_capture = re.compile(posix_to_python(CANONICAL_RL_ARRAY_CAPTURE))
    uncast = "v_allowed_buckets text[] := ARRAY[\n  'a',\n  'b'\n];"
    casted = "v_allowed_buckets text[] := ARRAY[\n  'a',\n  'b'\n]::text[];"
    if py_init.search(uncast) is None or py_capture.search(uncast) is None:
        fail("canonical parser does not match uncast ARRAY[...]; form")
    if py_init.search(casted) is None or py_capture.search(casted) is None:
        fail("canonical parser does not match ARRAY[...]::text[]; form")
    uncast_inner = py_capture.search(uncast)
    casted_inner = py_capture.search(casted)
    assert uncast_inner is not None and casted_inner is not None
    if "'a'" not in uncast_inner.group(2) or "'b'" not in uncast_inner.group(2):
        fail("uncast ARRAY capture did not isolate quoted bucket tokens")
    if "'a'" not in casted_inner.group(2) or "'b'" not in casted_inner.group(2):
        fail("casted ARRAY capture did not isolate quoted bucket tokens")
    if "::text[]" in uncast_inner.group(2) or "::text[]" in casted_inner.group(2):
        fail("ARRAY capture must not include the optional ::text[] cast in the inner region")


def require(haystack: str, needle: str, why: str) -> None:
    if needle not in haystack:
        fail(f"{why}: missing {needle!r}")


def update_rpc_body(sql: str) -> str:
    start = sql.find("CREATE OR REPLACE FUNCTION public.update_fan_team_discovery")
    if start < 0:
        fail("update_fan_team_discovery missing")
    end = sql.find("REVOKE ALL ON FUNCTION public.update_fan_team_discovery", start)
    if end < 0:
        fail("could not bound update_fan_team_discovery")
    return sql[start:end]


def assert_transaction_order(sql: str) -> None:
    """FAIL if COMMIT appears before the final migration postflight."""
    commits = [m.start() for m in COMMIT_RE.finditer(sql)]
    if len(commits) != 1:
        fail(f"expected exactly one COMMIT;, found {len(commits)}")
    commit_at = commits[0]

    begins = [m.start() for m in BEGIN_RE.finditer(sql)]
    if not begins:
        fail("BEGIN; missing")
    if begins[0] > commit_at:
        fail("BEGIN; must precede COMMIT;")
    if any(pos > commit_at for pos in begins):
        fail("BEGIN; appears after COMMIT;")

    first_write: int | None = None
    for pat in (r"(?m)^ALTER TABLE", r"(?m)^CREATE OR REPLACE FUNCTION"):
        match = re.search(pat, sql)
        if match and (first_write is None or match.start() < first_write):
            first_write = match.start()
    if first_write is None:
        fail("no schema writes found")
    if first_write < begins[0]:
        fail("BEGIN must occur before writes")

    postflight_markers = (
        "20261000 is_discoverable missing",
        "update_fan_team_discovery must call assert_rpc_rate_limit",
        "ARRAY missing update_fan_team_discovery",
        "update_fan_team_discovery must preserve location unless p_clear_location is true",
        "authenticated must EXECUTE update_fan_team_discovery",
    )
    for marker in postflight_markers:
        idx = sql.find(marker)
        if idx < 0:
            fail(f"postflight marker missing: {marker}")
        if idx > commit_at:
            fail(f"final verification occurs before COMMIT: {marker!r} is after COMMIT")

    after = sql[commit_at + len("COMMIT;") :]
    if re.search(r"(?im)^\s*DO\s+\$", after):
        fail("there is a post-COMMIT correctness DO block")
    leftover = re.sub(r"(?m)^\s*--.*$", "", after).strip()
    if leftover:
        fail("COMMIT is not the last transactional action")


def assert_location_preservation(sql: str) -> None:
    body = update_rpc_body(sql)
    require(
        body,
        "Preserve stored discovery location unless p_clear_location is explicitly true.",
        "1/4 Discover OFF omit-location must preserve stored location",
    )
    require(body, "v_location_absent", "omitted/null location path missing")
    require(body, "v_clear boolean := coalesce(p_clear_location, false)", "p_clear_location must be authoritative")
    require(
        body,
        "v_place := coalesce(v_place, v_old_place);",
        "4. partial location update must preserve unspecified place",
    )
    require(
        body,
        "v_address := coalesce(v_address, v_old_address);",
        "4. partial location update must preserve unspecified address",
    )
    require(
        body,
        "v_city := coalesce(v_city, v_old_city);",
        "4. partial location update must preserve unspecified city",
    )
    require(
        body,
        "v_region := coalesce(v_region, v_old_region);",
        "4. partial location update must preserve unspecified region",
    )
    require(
        body,
        "v_postal := coalesce(v_postal, v_old_postal);",
        "4. partial location update must preserve unspecified postal",
    )
    require(
        body,
        "v_country := coalesce(v_country, v_old_country);",
        "4. partial location update must preserve unspecified country",
    )
    require(
        body,
        "v_lat := coalesce(v_lat, v_old_lat);",
        "4. partial location update must preserve unspecified latitude",
    )
    require(
        body,
        "v_lng := coalesce(v_lng, v_old_lng);",
        "4. partial location update must preserve unspecified longitude",
    )
    require(
        body,
        "Patch unspecified location fields from the stored row (supplied ?? old).",
        "partial location patch comment missing",
    )

    # 1 + 4: hidden / Discover OFF + p_clear_location=false preserves stored fields
    require(
        body,
        "Omitted/null location arguments while Discover is OFF must not wipe a",
        "Discover OFF save must not erase saved location",
    )
    if re.search(
        r"IF v_location_absent THEN[\s\S]*?looking_for_players = v_looking[\s\S]*?"
        r"sport_subtype = v_subtype[\s\S]*?updated_at = now\(\)",
        body,
    ) is None:
        fail("4. Discover OFF + p_clear_location=false must UPDATE flags only (preserve location columns)")
    preserve = body.split("IF v_location_absent THEN", 1)[1].split("RETURN;", 1)[0]
    if "discovery_place_name = NULL" in preserve or "discovery_latitude = NULL" in preserve:
        fail("preserve path must not NULL location columns")

    # 2 + 3: Discover ON validates the FINAL merged location
    require(
        body,
        "Validate the final merged location, not raw incoming arguments.",
        "7. Discover ON must validate the final merged location",
    )
    require(
        body,
        "Choose a Team location before showing this Team on Discover.",
        "2/3 Discover ON location validation missing",
    )
    require(
        body,
        "v_old_lat, v_old_lng, v_old_country, v_old_city, v_old_place",
        "3. Discover ON with no supplied location must validate stored location",
    )
    require(
        body,
        "v_lat, v_lng, v_country, v_city, v_place",
        "2. Discover ON must validate merged lat/lng/country/city/place",
    )

    # 5: explicit clear
    require(body, "IF v_clear AND NOT v_discoverable THEN", "5. explicit clear branch missing")
    clear_branch = body.split("IF v_clear AND NOT v_discoverable THEN", 1)[1].split("END IF;", 1)[0]
    for col in (
        "discovery_place_name = NULL",
        "discovery_address = NULL",
        "discovery_city = NULL",
        "discovery_region = NULL",
        "discovery_postal_code = NULL",
        "discovery_country_code = NULL",
        "discovery_latitude = NULL",
        "discovery_longitude = NULL",
    ):
        require(clear_branch, col, "5. Discover OFF + p_clear_location=true must clear location")

    # 6: Looking for Players independent of Discover
    if body.count("looking_for_players = v_looking") < 3:
        fail("6. looking_for_players must persist on clear, preserve, and write paths")
    require(
        sql,
        "Independent of is_discoverable; never publishes a hidden Team.",
        "6. Looking for Players must remain independent of Discover",
    )

    # 7: General Area privacy unchanged
    require(body, "IF v_precision = 'general_area' THEN", "7. general_area handling missing")
    require(body, "v_address := NULL;", "7. general_area must NULL address")
    require(body, "v_postal := NULL;", "7. general_area must NULL postal")

    # 8: existing Teams default discoverable false
    require(
        sql,
        "is_discoverable boolean NOT NULL DEFAULT false",
        "8. existing Teams must default is_discoverable false",
    )


def main() -> None:
    if not TARGET.exists():
        fail(f"missing {TARGET}")
    if (MIGRATIONS / "20261001_0001_fan_team_discoverability.sql").exists():
        fail("unexpected 20261001 repair migration")

    sql = TARGET.read_text(encoding="utf-8")
    rl = rate_limit_section(sql)
    callers = perform_buckets()
    contract = repo_contract(sql)

    missing = sorted(callers - contract)
    if missing:
        fail(f"v_repo missing PERFORM buckets: {missing}")

    if "update_fan_team_discovery" not in contract:
        fail("v_repo missing update_fan_team_discovery")
    if "update_fan_team_discovery" not in callers:
        fail("update_fan_team_discovery is not called via assert_rpc_rate_limit")

    # 1. pg_get_functiondef is used
    require(
        rl,
        "pg_get_functiondef(",
        "live full definition must be read with pg_get_functiondef",
    )
    require(
        rl,
        "'public.assert_rpc_rate_limit(text,integer,integer)'::regprocedure",
        "pg_get_functiondef must target the live (text,integer,integer) signature",
    )

    # 2. live full definition is captured
    require(rl, "v_def := pg_get_functiondef(", "live full definition is not captured")
    require(
        rl,
        "pg_get_functiondef returned NULL",
        "NULL pg_get_functiondef must fail closed",
    )

    # 3. only the ARRAY initializer is substituted
    require(rl, "v_allowed_buckets", "ARRAY initializer locator missing")
    require(
        rl,
        "expected exactly one v_allowed_buckets initializer",
        "ambiguous parsing must fail closed",
    )
    require(rl, "v_old_full", "live initializer capture missing")
    require(rl, "v_new_full", "patched initializer capture missing")
    require(rl, "v_new_def", "minimally patched live definition missing")
    require(
        rl,
        "replacement changed more than the ARRAY initializer",
        "replacement must prove it touched only the ARRAY region",
    )
    require(
        rl,
        "EXECUTE v_new_def",
        "must EXECUTE the minimally patched live definition",
    )

    # 4. NO hard-coded limiter body in the 20261000 rate-limit merge
    if re.search(
        r"CREATE\s+OR\s+REPLACE\s+FUNCTION\s+public\.assert_rpc_rate_limit\s*\(",
        sql,
        flags=re.IGNORECASE,
    ):
        fail("20261000 still has a static CREATE OR REPLACE FUNCTION assert_rpc_rate_limit body")

    for fragment in HARD_CODED_LIMITER_FRAGMENTS:
        if fragment in rl:
            fail(
                "20261000 rate-limit merge still contains hard-coded limiter "
                f"implementation fragment: {fragment!r}"
            )

    # 5–6. current repository buckets + update_fan_team_discovery
    require(rl, "'update_fan_team_discovery'", "update_fan_team_discovery not in merge")
    for bucket in sorted(contract):
        if f"'{bucket}'" not in rl:
            fail(f"v_repo bucket {bucket!r} is not present in the rate-limit merge")

    # 7. live bucket preservation is verified
    require(rl, "dropped live buckets", "live bucket preservation is not verified")
    require(
        rl,
        "merged allowlist smaller than live ARRAY",
        "merged set must not shrink vs live",
    )

    # 8. ambiguous parsing fails closed
    require(
        rl,
        "cannot parse live assert_rpc_rate_limit ARRAY",
        "unparseable initializer must fail closed",
    )
    require(
        rl,
        "parsed zero buckets",
        "zero live buckets must fail closed",
    )

    # Skip rewrite when merged == live
    require(
        rl,
        "already contains merged allowlist; skip rewrite",
        "equal merged/live sets must not replace the function",
    )

    # 9. SECURITY DEFINER is verified afterward
    require(
        rl,
        "lost SECURITY DEFINER",
        "SECURITY DEFINER is not verified after patch",
    )
    require(rl, "prosecdef", "catalog SECURITY DEFINER flag is not checked")

    # 10. privileges are verified afterward (not blindly reset)
    require(
        rl,
        "must not be executable by anon/authenticated",
        "anon/authenticated EXECUTE denial is not verified",
    )
    require(
        rl,
        "service_role must EXECUTE assert_rpc_rate_limit",
        "service_role EXECUTE is not verified",
    )
    if re.search(
        r"REVOKE\s+ALL\s+ON\s+FUNCTION\s+public\.assert_rpc_rate_limit",
        rl,
        flags=re.IGNORECASE,
    ):
        fail("rate-limit merge resets privileges instead of verifying the canonical contract")
    if re.search(
        r"GRANT\s+EXECUTE\s+ON\s+FUNCTION\s+public\.assert_rpc_rate_limit",
        rl,
        flags=re.IGNORECASE,
    ):
        fail("rate-limit merge re-grants privileges instead of verifying the canonical contract")

    if "is_discoverable boolean NOT NULL DEFAULT false" not in sql:
        fail("discovery default OFF changed")
    if "list_discoverable_fan_teams_in_bounds" not in sql:
        fail("public-safe list RPC missing")
    if "fan_teams_discoverable_requires_location_ck" not in sql:
        fail("discoverable location invariant missing")

    assert_transaction_order(sql)
    assert_location_preservation(sql)

    checks = ROOT / "supabase" / "tests" / "fan_team_discoverability_checks.sql"
    if not checks.exists():
        fail("missing fan_team_discoverability_checks.sql")
    checks_sql = checks.read_text(encoding="utf-8")
    assert_canonical_array_parser(sql, checks_sql)
    for needle in (
        "Hidden Team + saved location",
        "Discover ON + valid location",
        "Discover ON + no stored/supplied location",
        "p_clear_location=false",
        "p_clear_location=true",
        "Looking for Players ON + Discover OFF",
        "General Area",
        "default is_discoverable false",
        "Partial location payload",
    ):
        require(checks_sql, needle, "discoverability catalog checks")

    print("PASS 20261000 rate-limit source checks")
    print("repository PERFORM buckets:")
    for name in sorted(callers):
        print(f"  - {name}")
    print("v_repo contract buckets:")
    for name in sorted(contract):
        print(f"  - {name}")
    extra = sorted(contract - callers)
    if extra:
        print("contract-only extras (allowed):")
        for name in extra:
            print(f"  - {name}")


if __name__ == "__main__":
    main()
