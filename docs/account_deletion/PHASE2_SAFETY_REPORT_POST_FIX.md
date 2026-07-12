# Phase 2 Account Deletion — Post-Fix Safety Report

**Migration:** `supabase/migrations/20260843_0001_user_account_deletion_phase2.sql`  
**Date:** 2026-07-10  
**Status:** Safe for **staging apply** after review. **Not** approved for production.

## Executive summary

All blocking (P0) and required (P1–P2) issues from the pre-fix review are addressed in the migration SQL and aligned Edge Function source. Hard Auth deletion remains disabled. Phase 2 soft-deletion semantics are unchanged.

| Issue | Severity | Resolution |
|-------|----------|------------|
| `advance_account_deletion_job` granted to `authenticated` | P0 | Revoked from `authenticated`; service_role only; action whitelist |
| Incomplete business/venue blockers | P1 | `business_ownership`, `business_email_ownership`, `venue_ownership`, `pending_venue_claim` |
| Failed-job retry rolls back `failed` status | P1/P2 | Structured `ok:false` return without rethrow; retry when `failed` + `db_cleanup` + profile not anonymized |
| `request_delete_my_account` stale response | P2 | Re-reads job; `finalize_queue` / `finalize_queued` reflect actual queue outcome |
| Profile location/identity PII not cleared | P2 | Clears home_*, national_team_*, presence, display_name_normalized, etc. |
| Brittle `current_setting('role')` | P3 | JWT `role` claim only via `request.jwt.claim.role` / `auth.jwt()` |
| Identity guard breaks anonymization | P0/P1 | Transaction-local `gameon.account_deletion_anonymize` bypass in trigger |

## P0 — `advance_account_deletion_job` lockdown

- **EXECUTE** revoked from `authenticated` and `PUBLIC`.
- **EXECUTE** granted only to `service_role`.
- Legacy 6-parameter overload dropped via `DROP FUNCTION IF EXISTS`.
- New API: `advance_account_deletion_job(p_job_id, p_action, p_error_code?, p_error_detail?)`.
- Whitelisted actions:
  - `mark_storage_pending`: `db_committed` or `storage_pending` → `storage_pending` / `storage_cleanup`
  - `mark_completed`: `storage_pending` → `completed` / `completed` (sets `completed_at`)
  - `mark_storage_partial`: `storage_pending` → `storage_pending` / `storage_cleanup_partial`
- `completed` is terminal: further calls return `idempotent_replay: true` without mutating state.
- Service-role gate at function entry (`gameon_account_deletion_is_service_caller()`).

**Residual risk:** Low. Only service_role (Edge Function / pg_net) can mark jobs completed.

## P1 — Business/venue ownership blockers

`gameon_account_deletion_block_reason()` now returns:

| Reason | Condition |
|--------|-----------|
| `business_ownership` | Any `businesses.owner_user_id = p_user_id` (any admin_status) |
| `business_email_ownership` | `owner_user_id IS NULL` and normalized `owner_email` matches resolved email |
| `venue_ownership` | Any `venues.owner_user_id = p_user_id` |
| `pending_venue_claim` | Open/pending `venue_claims` tied to owner email or owned business |

Checked in preview (`gameon_account_deletion_block_reason`), job creation (`gameon_account_deletion_assert_deletable` via `start_account_deletion_job`), and execute (`execute_delete_user_account_db`).

## P1/P2 — Failed-job retry

- DB cleanup runs in inner `BEGIN … EXCEPTION` block.
- On failure: job updated to `status=failed`, `stage=db_cleanup`, returns `ok:false` JSON — **no rethrow**.
- Retry allowed when `status=failed`, `stage=db_cleanup`, and profile is **not** anonymized.
- Retry **blocked** after partial commit (`db_committed`, `storage_pending`, `completed`).

## P2 — `request_delete_my_account` accuracy

- `queue_account_deletion_finalize` returns `{queued, result}` where `result` ∈ `queued`, `skipped_missing_secrets`, `skipped_pg_net_unavailable`, `failed`.
- Orchestrator re-reads job row before return; `status`/`stage` are current.
- `finalize_queued` is `true` only when queue actually succeeded.
- Authenticated self-service path returns `skipped_client_finalize` (iOS calls Edge Function directly).

## P2 — Profile PII clearing

Anonymization clears (schema-defensive, column-exists checks):

- `home_city`, `home_region`, `home_country`, `show_home_city`
- `national_team_*` fields
- `home_crowd_*`, presence (`last_seen_at`, `last_active_at`)
- `display_name_normalized`, handles, bio, avatars, discoverability, fan preferences
- Tombstone fields preserved: `is_deleted`, `deleted_at`, `anonymized_at`, `display_name` ("Deleted User"), deleted-local `email`

No `last_location_*` columns exist in current schema.

## P3 — Service-role detection

```sql
coalesce(
  nullif(btrim(current_setting('request.jwt.claim.role', true)), ''),
  nullif(btrim(coalesce(auth.jwt() ->> 'role', '')), ''),
  ''
) = 'service_role'
```

No `current_setting('role')` fallback.

## Identity guard compatibility

- `enforce_fan_account_identity_guard()` updated in this migration.
- Bypass: `current_setting('gameon.account_deletion_anonymize', true) = NEW.id::text`
- GUC set only inside `gameon_account_deletion_soft_delete_core` (not granted to clients), transaction-local (`is_local=true`).
- `account_identities` row unchanged in Phase 2 — intentional.

## Grants matrix (verified in staging checks)

| RPC | authenticated | service_role |
|-----|---------------|--------------|
| `preview_delete_user_account` | ✓ | ✓ |
| `start_account_deletion_job` | ✓ | ✓ |
| `execute_delete_user_account_db` | ✓ | ✓ |
| `request_delete_my_account` | ✓ | — |
| `advance_account_deletion_job` | ✗ | ✓ |
| `queue_account_deletion_finalize` | ✗ | ✓ |
| Internal `gameon_account_deletion_*` helpers | ✗ | ✗ (no grants) |
| `SELECT` own `account_deletion_jobs` | ✓ (RLS) | ✓ |

## Edge Function alignment

`supabase/functions/finalize-account-deletion/index.ts` updated to call `p_action` API. **Not deployed** per instructions.

## Staging test coverage

`supabase/tests/account_deletion_phase2_staging_checks.sql` validates:

- Object presence and legacy overload absence
- Grant matrix
- Transition whitelist + terminal `completed`
- Business/venue/email-only blockers
- Identity guard bypass in function body
- Accurate `request_delete_my_account` response fields
- Structured execute failure (no bare `RAISE;`)
- PII clearing + bypass GUC in soft-delete core

Manual staging tests still required for end-to-end deletion of a dedicated test user.

## Staging readiness verdict

**SAFE FOR STAGING APPLY** with these preconditions:

1. Apply migration on staging only; do not deploy Edge Function until separately approved.
2. Run `supabase/tests/account_deletion_phase2_staging_checks.sql` after apply.
3. Run one dedicated test-user deletion (preview → start → execute → finalize).
4. Confirm iOS build succeeds against current API (separate RPC path, not `request_delete_my_account` orchestrator).

## Not in scope (unchanged)

- `auth.users` deletion
- `account_identities` deletion / email release
- Admin purge tooling
- Production deploy
