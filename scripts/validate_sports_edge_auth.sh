#!/usr/bin/env bash
# Validation plan for privileged sports Edge Function auth.
# Does not print secret values. Requires env:
#   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY
# Optional:
#   USER_JWT (ordinary authenticated JWT), SYNC_LIVE_MATCHES_CRON_SECRET, IMPORT_GAMES_CRON_SECRET
#
# Usage:
#   ./scripts/validate_sports_edge_auth.sh
set -euo pipefail

: "${SUPABASE_URL:?set SUPABASE_URL}"
: "${SUPABASE_ANON_KEY:?set SUPABASE_ANON_KEY}"
: "${SUPABASE_SERVICE_ROLE_KEY:?set SUPABASE_SERVICE_ROLE_KEY}"

BASE="${SUPABASE_URL%/}/functions/v1"
PASS=0
FAIL=0

expect_status() {
  local name="$1"
  local want="$2"
  local got="$3"
  if [[ "$got" == "$want" ]]; then
    echo "PASS  $name (HTTP $got)"
    PASS=$((PASS + 1))
  else
    echo "FAIL  $name (want HTTP $want, got $got)"
    FAIL=$((FAIL + 1))
  fi
}

post_status() {
  local path="$1"
  shift
  curl -sS -o /dev/null -w "%{http_code}" -X POST "${BASE}/${path}" \
    -H "Content-Type: application/json" \
    "$@" \
    -d '{}'
}

echo "== Local Deno unit tests =="
deno test --allow-env supabase/functions/_shared/sports_worker_auth_test.ts

echo
echo "== HTTP auth matrix (live project) =="

for fn in sync-live-matches import-games; do
  code="$(post_status "$fn")"
  expect_status "$fn no Authorization" "401" "$code"

  code="$(post_status "$fn" -H "Authorization: Bearer ${SUPABASE_ANON_KEY}" -H "apikey: ${SUPABASE_ANON_KEY}")"
  expect_status "$fn anon key" "401" "$code"

  if [[ -n "${USER_JWT:-}" ]]; then
    code="$(post_status "$fn" -H "Authorization: Bearer ${USER_JWT}" -H "apikey: ${SUPABASE_ANON_KEY}")"
    expect_status "$fn user JWT" "401" "$code"
  else
    echo "SKIP  $fn user JWT (set USER_JWT to exercise)"
  fi

  code="$(post_status "$fn" -H "x-cron-secret: wrong-secret")"
  expect_status "$fn wrong cron secret" "401" "$code"

  code="$(post_status "$fn" -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}")"
  # Authorized calls may return 200 or 500 (provider/env), but must not be 401/403.
  if [[ "$code" == "401" || "$code" == "403" ]]; then
    expect_status "$fn service role bearer" "200" "$code"
  else
    echo "PASS  $fn service role bearer (HTTP $code — not unauthorized)"
    PASS=$((PASS + 1))
  fi
done

if [[ -n "${SYNC_LIVE_MATCHES_CRON_SECRET:-}" ]]; then
  code="$(post_status sync-live-matches -H "x-cron-secret: ${SYNC_LIVE_MATCHES_CRON_SECRET}")"
  if [[ "$code" == "401" || "$code" == "403" ]]; then
    expect_status "sync-live-matches correct cron secret" "200" "$code"
  else
    echo "PASS  sync-live-matches correct cron secret (HTTP $code — not unauthorized)"
    PASS=$((PASS + 1))
  fi
fi

echo
echo "Result: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
