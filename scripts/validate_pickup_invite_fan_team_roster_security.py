#!/usr/bin/env python3
"""Static security + preview/send consistency checks for 20260938.

Does not apply SQL. Validates the migration source against the approved
authorization split and the A–K preview/send matrix invariants.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / "supabase/migrations/20260938_0001_pickup_invite_fan_team_roster.sql"
PROD_CREATE = ROOT / "supabase/migrations/20260803_0002_pickup_invitable_fan_search.sql"


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    raise SystemExit(1)


def extract_function(sql: str, name: str) -> str:
    # Capture from CREATE OR REPLACE FUNCTION ... name( through the matching $$;
    pattern = re.compile(
        rf"CREATE OR REPLACE FUNCTION public\.{re.escape(name)}\s*\(.*?\$\$;",
        re.DOTALL | re.IGNORECASE,
    )
    matches = pattern.findall(sql)
    if not matches:
        fail(f"function {name} not found")
    return matches[-1]


def assert_contains(body: str, needle: str, ctx: str) -> None:
    if needle not in body:
        fail(f"{ctx}: missing `{needle}`")


def assert_not_contains(body: str, needle: str, ctx: str) -> None:
    if needle in body:
        fail(f"{ctx}: must not contain `{needle}`")


def main() -> None:
    if not MIGRATION.is_file():
        fail(f"missing migration {MIGRATION}")
    sql = MIGRATION.read_text(encoding="utf-8")
    prod = PROD_CREATE.read_text(encoding="utf-8") if PROD_CREATE.is_file() else ""

    generic = extract_function(sql, "create_pickup_game_invites")
    team_bulk = extract_function(sql, "create_pickup_game_invites_from_fan_team")
    preview = extract_function(sql, "preview_pickup_game_fan_team_invite")

    # --- I: Generic RPC remains free of Team eligibility helper ---
    assert_not_contains(generic, "pickup_invite_eligible_via_managed_fan_team", "I generic")
    assert_not_contains(generic, "fan_team_members", "I generic")
    assert_not_contains(generic, "fan_team_viewer_can_manage", "I generic")
    assert_contains(generic, "pickup_invite_users_are_friends", "I generic friend gate")
    assert_contains(generic, "pickup_invite_user_is_public_invitable", "I generic public gate")

    # Drop helper if present historically
    assert_contains(
        sql,
        "DROP FUNCTION IF EXISTS public.pickup_invite_eligible_via_managed_fan_team",
        "I drop helper",
    )

    # --- J: Team bulk does not delegate to generic RPC ---
    assert_not_contains(team_bulk, "create_pickup_game_invites(", "J no delegate")
    assert_not_contains(team_bulk, "PERFORM public.create_pickup_game_invites", "J no delegate")
    assert_contains(team_bulk, "fan_team_viewer_can_manage", "J manage gate")
    assert_contains(team_bulk, "fan_team_members", "J roster")
    assert_not_contains(team_bulk, "pickup_invite_users_are_friends", "J no friend req")
    assert_not_contains(team_bulk, "pickup_invite_user_is_public_invitable", "J no public req")
    assert_contains(team_bulk, "INSERT INTO public.pickup_game_invites", "J normal invite rows")

    # --- K: Non-manager cannot preview or send ---
    assert_contains(preview, "fan_team_viewer_can_manage", "K preview manage")
    assert_contains(team_bulk, "fan_team_invite_not_allowed", "K send manage exception")
    assert_contains(preview, "fan_team_invite_not_allowed", "K preview manage exception")

    # --- Production cancelled-invite semantics (preserve) ---
    # Production duplicate check has no status <> 'cancelled' filter.
    prod_generic = extract_function(prod, "create_pickup_game_invites") if prod else ""
    if prod_generic:
        dup_block = re.search(
            r"SELECT i\.id INTO existing_id.*?LIMIT 1;",
            prod_generic,
            re.DOTALL,
        )
        if not dup_block:
            fail("production duplicate block not found")
        if "status <> 'cancelled'" in dup_block.group(0) or "status != 'cancelled'" in dup_block.group(0):
            fail("production duplicate unexpectedly filters cancelled — revisit re-invite policy")
        print("OK: production cancelled invites are non-reinviteable (duplicate on any row)")

    # Generic + Team Send: ANY invite row => duplicate (no cancelled filter on existing_id lookup)
    for name, body in (("generic", generic), ("team_bulk", team_bulk)):
        dup_block = re.search(
            r"SELECT i\.id INTO existing_id.*?LIMIT 1;",
            body,
            re.DOTALL,
        )
        if not dup_block:
            fail(f"{name}: existing invite lookup missing")
        if re.search(r"status\s*<>\s*'cancelled'", dup_block.group(0)):
            fail(f"{name}: duplicate lookup must NOT filter cancelled (C)")
        assert_contains(body, "outcome := 'duplicate'", f"{name} duplicate outcome")

    # Cap counts exclude cancelled (both Send paths)
    for name, body in (("generic", generic), ("team_bulk", team_bulk)):
        assert_contains(body, "AND i.status <> 'cancelled'", f"{name} active cap")
        assert_contains(body, "outcome := 'max_reached'", f"{name} max_reached")

    # --- C + preview cancelled alignment ---
    # Preview already_invited must use EXISTS without status <> cancelled.
    if "status <> 'cancelled'" in preview and preview.count("status <> 'cancelled'") != 1:
        # Only the game-wide active_invite_count may filter cancelled.
        cancelled_filters = [
            m.start() for m in re.finditer(r"status\s*<>\s*'cancelled'", preview)
        ]
        if len(cancelled_filters) != 1:
            fail("C preview: expected exactly one status <> 'cancelled' (active cap only)")
    assert_contains(preview, "THEN 'already_invited'", "C preview class")
    # Ensure already_invited EXISTS block does not filter cancelled
    invited_case = re.search(
        r"WHEN EXISTS \(\s*SELECT 1\s*FROM public\.pickup_game_invites i.*?\) THEN 'already_invited'",
        preview,
        re.DOTALL,
    )
    if not invited_case:
        fail("C preview: already_invited EXISTS block missing")
    if "cancelled" in invited_case.group(0):
        fail("C preview: already_invited must count ANY invite row including cancelled")

    # --- G/H: 50-cap in preview ---
    assert_contains(preview, "v_remaining_slots := greatest(0, 50 - v_active_invite_count)", "G remaining")
    assert_contains(preview, "v_eligible := least(v_raw_eligible, v_remaining_slots)", "G cap eligible")
    assert_contains(
        preview,
        "v_ineligible := v_ineligible + (v_raw_eligible - v_eligible)",
        "G overflow to ineligible",
    )

    # --- Preview/Send mapping labels ---
    for outcome in (
        "created",
        "duplicate",
        "already_playing",
        "already_pending",
        "max_reached",
        "skipped",
    ):
        assert_contains(team_bulk, f"'{outcome}'", f"send outcome {outcome}")

    for cls in (
        "already_invited",
        "already_playing",
        "already_pending",
        "ineligible",
        "raw_eligible",
    ):
        assert_contains(preview, f"'{cls}'", f"preview class {cls}")

    # Preview must not require friend/public
    assert_not_contains(preview, "pickup_invite_users_are_friends", "preview no friend")
    assert_not_contains(preview, "pickup_invite_user_is_public_invitable", "preview no public")

    # No Team invite table
    assert_not_contains(sql, "CREATE TABLE", "no new tables")
    assert_not_contains(sql, "fan_team_game_invite", "no Team invite table")

    # Matrix narrative checks (static documentation of A–F expectations in comments / code)
    assert_contains(sql, "including status='cancelled'", "docs cancelled")
    assert_contains(sql, "eligible_count is capped by remaining active-invite slots", "docs cap")

    print("OK: A–K static matrix + security separation validated for 20260938")
    print("Mapping:")
    print("  eligible        → created (subject to concurrency)")
    print("  already_invited → duplicate  (ANY invite row, incl. cancelled)")
    print("  already_playing → already_playing")
    print("  already_pending → already_pending")
    print("  cap overflow    → max_reached (folded into ineligible_count in preview)")
    print("  ineligible      → skipped")
    print("SAFE TO APPLY: yes (after prior Team/pickup migrations; do not auto-apply)")


if __name__ == "__main__":
    main()
