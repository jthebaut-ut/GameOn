# Edge Function cron secrets (dedicated — no cross-worker reuse)

Review-ready ops note after 2026-08 security hardening. **Do not print secret values.**

## Rules

1. Prefer `Authorization: Bearer <SUPABASE_SERVICE_ROLE_KEY>` for pg_net / internal workers.
2. Optional `x-cron-secret` / `x-fangeo-cron-secret` must match **only** that function’s dedicated env var.
3. **Never** fall back from one worker’s secret to another (announcement ↔ plus ↔ business ↔ pickup ↔ sync ↔ pro-score).

## Dedicated secret names

| Edge Function | Dedicated cron env (optional) |
|---|---|
| `notify-fangeo-announcement` | `FANGEO_ANNOUNCEMENT_PUSH_CRON_SECRET` |
| `notify-fangeo-plus-award` | `FANGEO_PLUS_AWARD_PUSH_CRON_SECRET` |
| `notify-business-pro-award` | `BUSINESS_PRO_AWARD_PUSH_CRON_SECRET` |
| `notify-pickup-game-change` | `PICKUP_GAME_CHANGE_PUSH_CRON_SECRET` |
| `notify-support-reply` | `SUPPORT_REPLY_PUSH_CRON_SECRET` |
| `pro-game-score-alert-worker` | `PRO_SCORE_PUSH_WORKER_CRON_SECRET` |
| `sync-live-matches` | `SYNC_LIVE_MATCHES_CRON_SECRET` or `SPORTS_SYNC_CRON_SECRET` |
| `import-games` | `IMPORT_GAMES_CRON_SECRET` or `SPORTS_SYNC_CRON_SECRET` |
| `finalize-business-account-deletion` | **service-role bearer only** (exact key match) |
| `venue-claim-approve` / `reject` | JWT link secret `ADMIN_VENUE_CLAIM_LINK_SECRET` (not cron) |

## Cross-call note

`pro-game-score-alert-worker` refreshes live matches by calling `sync-live-matches` with the **service-role bearer**, not by forwarding `PRO_SCORE_PUSH_WORKER_CRON_SECRET`.

## Vault / pg_net

Store secrets in Vault under the same names. Cron SQL must reference Vault secret **names**, never literal keys in `cron.job`.
