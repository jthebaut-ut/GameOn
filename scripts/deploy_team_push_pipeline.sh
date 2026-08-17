#!/usr/bin/env bash
# FanGeo — Team push notification deployment (linked project)
# Run from repo root on a machine with Supabase CLI access + DB password.
# Does NOT print secrets. Does NOT commit/push.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PROJECT_REF="$(cat supabase/.temp/project-ref 2>/dev/null || true)"
if [[ -z "${PROJECT_REF}" ]]; then
  echo "ERROR: supabase/.temp/project-ref missing — run supabase link first"
  exit 1
fi

if [[ -z "${SUPABASE_DB_PASSWORD:-}" ]]; then
  if security find-generic-password -s "Supabase CLI" -w >/dev/null 2>&1; then
    export SUPABASE_DB_PASSWORD="$(security find-generic-password -s "Supabase CLI" -w)"
  else
    echo "ERROR: set SUPABASE_DB_PASSWORD or store it in Keychain (Supabase CLI)"
    exit 1
  fi
fi

echo "== Project ref: ${PROJECT_REF} =="
echo "== 1) Migration list (inspect BEFORE apply) =="
supabase migration list --linked | tee /tmp/fangio_team_push_mig_list.txt
echo
echo "Look for 20260954 / 20260974 / 20260975 / 20260976 / 20260982 — Remote column empty = MISSING"

echo
echo "== 2) Apply ONLY missing migrations (db push is incremental) =="
echo "Review the list above. Continuing with supabase db push --linked --include-all ..."
read -r -p "Type APPLY to continue: " CONFIRM
if [[ "$CONFIRM" != "APPLY" ]]; then
  echo "Aborted."
  exit 1
fi

supabase db push --linked --include-all

echo
echo "== 3) Verify remote objects =="
supabase db query --linked "$(cat <<'SQL'
SELECT
  to_regprocedure('public.list_pickup_game_change_push_tokens(uuid,uuid)') IS NOT NULL AS has_list_tokens,
  to_regprocedure('public.queue_team_event_created_push_notification(uuid,uuid,uuid)') IS NOT NULL AS has_queue_create,
  to_regprocedure('public.is_fan_team_schedule_create_push_format(text)') IS NOT NULL AS has_schedule_format,
  to_regprocedure('public.is_fan_team_game_create_push_format(text)') IS NOT NULL AS has_game_format,
  to_regprocedure('public.is_fan_team_announcement_create_push_format(text)') IS NOT NULL AS has_announcement_format,
  to_regprocedure('public.link_pickup_game_to_fan_team(uuid,uuid)') IS NOT NULL AS has_link,
  to_regprocedure('public.emit_fan_team_member_change_notification(uuid,text,uuid,uuid,jsonb)') IS NOT NULL AS has_emit_member_change,
  to_regclass('public.fan_team_push_delivery_diagnostics') IS NOT NULL AS has_diagnostics_view;
SQL
)"

supabase db query --linked "$(cat <<'SQL'
SELECT
  public.is_fan_team_schedule_create_push_format('practice') AS practice_ok,
  public.is_fan_team_schedule_create_push_format('league_game') AS league_ok,
  public.is_fan_team_schedule_create_push_format('team_meeting') AS meeting_ok,
  public.is_fan_team_announcement_create_push_format('announcement') AS announcement_ok,
  public.is_fan_team_game_create_push_format('practice') AS practice_not_competitive;
SQL
)"

echo
echo "== 4) SQL self-check 20260982 =="
supabase db query --linked -f supabase/tests/20260982_team_schedule_create_push_all_formats_checks.sql

echo
echo "== 5) Deploy Edge Functions (pg_net workers use --no-verify-jwt) =="
supabase functions deploy notify-pickup-game-change --no-verify-jwt --project-ref "$PROJECT_REF"
supabase functions deploy notify-fan-team-member-change --no-verify-jwt --project-ref "$PROJECT_REF"

echo
echo "== 6) Secret presence (names only) =="
supabase secrets list --project-ref "$PROJECT_REF" 2>/dev/null | rg -i 'APNS_|PICKUP_GAME_CHANGE|FAN_TEAM_MEMBER_CHANGE|SERVICE_ROLE|SUPABASE_URL' || true

echo
echo "DONE. Next: two-iPhone checklist. Inspect fan_team_push_delivery_diagnostics after each test."
