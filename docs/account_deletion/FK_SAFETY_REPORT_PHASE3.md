# FK Safety Report — Phase 3 Hard Auth Deletion

**Status:** Review-only. Phase 2 does **not** delete `auth.users`. This document inventories every child row that would be affected if `auth.users(id)` were hard-deleted today, and proposes Phase 3 FK / tombstone changes.

**Generated for migration:** `20260843_0001_user_account_deletion_phase2.sql`

---

## Executive summary

| Category | Count | Phase 3 action |
|----------|------:|----------------|
| ON DELETE CASCADE (data loss risk) | 24 tables | Change to SET NULL or explicit soft-delete before auth delete |
| ON DELETE SET NULL (safe) | 4 columns | Keep or formalize tombstone |
| No FK (soft refs) | 12+ tables | Add tombstone views / SET NULL in execute RPC |
| Intentionally preserved today | 8 domains | Never CASCADE-delete in Phase 3 without policy sign-off |

**Recommendation:** Do not `DELETE FROM auth.users` until CASCADE policies on support, reports, and moderation tables are migrated to **SET NULL** or **RESTRICT + explicit anonymize**.

---

## 1. ON DELETE CASCADE — would be deleted with `auth.users`

These child rows are **removed automatically** if `auth.users` is hard-deleted without schema changes.

| Table | Column(s) | Risk | Phase 3 proposal |
|-------|-----------|------|------------------|
| `account_identities` | `account_id` | Email released | **DELETE** only after explicit hard-delete approval |
| `user_push_tokens` | `user_id` | Low | Already deleted in Phase 2 soft RPC — safe |
| `user_notification_preferences` | `user_id` | Low | Already deleted in Phase 2 |
| `user_favorite_teams` | `user_id` | Low | Already deleted in Phase 2 |
| `user_xp` | `user_id` | Low | Already deleted in Phase 2 |
| `xp_events` | `user_id` | Low | Already deleted in Phase 2 |
| `saved_pro_games` | `user_id` | Low | Already deleted in Phase 2 |
| `pro_game_predictions` | `user_id` | Low | Already deleted in Phase 2 |
| `pro_game_alert_subscriptions` | `user_id` | Low | Already deleted in Phase 2 |
| `pro_game_score_notification_deliveries` | `user_id` | Low | Already deleted in Phase 2 |
| `profile_likes` | `liker_user_id`, `liked_user_id` | Low | Already deleted in Phase 2 |
| `profile_props_recipient_clear` | `user_id` | Low | Already deleted in Phase 2 |
| `profile_pokes_recipient_clear` | `user_id` | Low | Already deleted in Phase 2 |
| `suggested_fan_dismissals` | `user_id`, `dismissed_user_id` | Low | Already deleted in Phase 2 |
| `blocked_users` | `blocker_user_id`, `blocked_user_id` | Low | Already deleted in Phase 2 |
| `pickup_game_invites` | `inviter_user_id`, `invitee_user_id` | Low | Already deleted in Phase 2 |
| `pickup_game_creator_ratings` | `creator_user_id`, `rater_user_id` | Low | Already deleted in Phase 2 |
| `pickup_games` | `creator_user_id` | **High** | Cancel/hide in RPC **before** auth delete; change FK to SET NULL |
| `pickup_game_requests` | `requester_user_id` | Medium | Withdraw in RPC first; FK → SET NULL |
| `venue_event_predictions` | `user_id` | Low | Already deleted in Phase 2 |
| `venue_event_comment_reactions` | `user_id` | Low | Already deleted in Phase 2 |
| `fangeo_plus_award_push_events` | `user_id` | Low | Already deleted in Phase 2 |
| `support_requests` | `user_id` | **Critical** | **CHANGE TO SET NULL** + anonymize reporter metadata |
| `support_conversations` | `user_id` | **Critical** | **CHANGE TO SET NULL** + tombstone `deleted_user_id` column |
| `user_reports` | `reporter_user_id`, `reported_user_id` | **Critical** | **CHANGE TO SET NULL** on both; preserve report body |
| `message_reports` | `reporter_user_id`, `reported_user_id` | **Critical** | **CHANGE TO SET NULL** |
| `conversation_reports` | `reporter_user_id` | **Critical** | **CHANGE TO SET NULL** |
| `venue_reports` | `reporter_user_id` | **Critical** | **CHANGE TO SET NULL** |

### Via `user_profiles(id)` CASCADE (only if profile row hard-deleted)

| Table | Column(s) | Phase 3 proposal |
|-------|-----------|------------------|
| `profile_pokes` | `poker_user_id`, `poked_user_id` | Deleted in Phase 2 RPC; keep profile row for soft delete |
| `user_bans` | `user_id` | **PRESERVE** — do not hard-delete profile if ban history required |
| `venue_event_comment_likes` | `user_id` | Deleted in Phase 2 |

---

## 2. ON DELETE SET NULL — safe today

| Table | Column | Behavior on auth delete |
|-------|--------|------------------------|
| `analytics_events` | `user_id` | Nullified (Phase 2 also nullifies in soft RPC) |
| `support_messages` | `sender_auth_user_id` | Sender nulled; message body preserved |
| `business_pro_award_push_events` | `owner_user_id` | Owner nulled |

**Phase 3:** Keep SET NULL; add optional `sender_display_label = 'Deleted User'` column on support messages for UI clarity.

---

## 3. No FK — survives `auth.users` delete (orphan refs)

| Table | Reference column(s) | Current Phase 2 | Phase 3 proposal |
|-------|---------------------|-----------------|------------------|
| `direct_messages` | `sender_id` | PRESERVE | Keep; UI shows Deleted User via profile tombstone |
| `direct_conversations` | `user_a_id`, `user_b_id` | PRESERVE | Keep |
| `venue_event_comments` | `user_email` | ANONYMIZE email | Keep |
| `friendships` | `requester_id`, `addressee_id` | ARCHIVE | Keep |
| `businesses` | `owner_user_id` | BLOCK fan delete | Business path only |
| `venues` | `owner_user_id` | BLOCK / business cascade | SET NULL on fan-only edge cases |
| `favorite_venues` | `user_email` | DELETE | N/A after Phase 2 |
| `venue_event_interests` | `user_email` | DELETE | N/A |
| `venue_event_vibes` | `user_email` | DELETE | N/A |
| `comment_reports` | reporter via email/uuid | PRESERVE | Audit column snapshot |
| `admin_audit_logs` | various | PRESERVE | Never delete |

---

## 4. Proposed Phase 3 migration themes (not applied)

### 4.1 Support & moderation — SET NULL + tombstone

```sql
-- REVIEW ONLY — Phase 3
ALTER TABLE public.support_requests
  ALTER COLUMN user_id DROP NOT NULL;
-- recreate FK: ON DELETE SET NULL

ALTER TABLE public.support_conversations
  ALTER COLUMN user_id DROP NOT NULL;
-- add: deleted_subject_user_id uuid NULL for audit

ALTER TABLE public.user_reports
  -- change both reporter_user_id and reported_user_id FKs to ON DELETE SET NULL
```

### 4.2 Pickup games — avoid game wipe

```sql
-- REVIEW ONLY — Phase 3
ALTER TABLE public.pickup_games
  DROP CONSTRAINT ...;
ALTER TABLE public.pickup_games
  ADD CONSTRAINT pickup_games_creator_user_id_fkey
  FOREIGN KEY (creator_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;
```

### 4.3 Identity release (explicit Phase 3 only)

```sql
-- REVIEW ONLY — only after legal/product approval
-- 1. execute_delete_user_account_db (hard mode)
-- 2. DELETE FROM account_identities WHERE account_id = ...
-- 3. auth.admin.deleteUser via Edge Function
```

---

## 5. Deletion order for Phase 3 hard mode (design)

1. Run Phase 2 soft-delete RPC (idempotent)
2. Verify zero private rows remain (integrity query pack in `supabase/tests/account_deletion_phase2_staging_checks.sql`)
3. Apply SET NULL FK migrations for support/reports
4. Edge Function: storage cleanup (Phase 2 function)
5. Edge Function: `auth.admin.deleteUser` — **separate flag `deletion_mode=hard`**
6. Verify `account_identities` CASCADE removed identity row
7. Job status → `completed`

---

## 6. Integrity queries (post soft-delete)

```sql
SELECT count(*) AS push_tokens_remaining
FROM public.user_push_tokens WHERE user_id = :uid;  -- expect 0

SELECT count(*) AS support_threads_preserved
FROM public.support_conversations WHERE user_id = :uid;  -- expect >= 0 unchanged

SELECT count(*) AS dms_preserved
FROM public.direct_messages WHERE sender_id = :uid;  -- expect >= 0 unchanged

SELECT is_deleted, email
FROM public.user_profiles WHERE id = :uid;  -- expect true, *@deleted.fangeo.local
```

---

## 7. Sign-off checklist before Phase 3

- [ ] Legal approves `auth.users` deletion and email re-registration policy
- [ ] Support/report CASCADE migrations applied on staging
- [ ] Pickup game FK changed to SET NULL or cancel-all verified
- [ ] Admin dashboard read-only history confirmed for deleted users
- [ ] PITR backup window documented
- [ ] `deletion_mode=hard` feature flag default **off**
