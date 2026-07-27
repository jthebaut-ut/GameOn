# FanGeo 13+ Age Access — Staging Rollout & Validation

**DO NOT run any of this against the linked production project.**
All commands below are for a separate staging project only. Nothing in this
document has been executed by tooling; it is a prepared runbook.

Migrations covered (forward-only, corrected in place before first apply — never
applied anywhere yet):

1. `supabase/migrations/20260886_0001_user_age_access.sql` — columns, freeze, sticky block, `record_user_age_access_result`
2. `supabase/migrations/20260887_0001_age_access_enforcement_core.sql` — mode + policy version config, mode-aware checks, trigger function
3. `supabase/migrations/20260888_0001_age_access_social_write_triggers.sql` — required/optional trigger attach (`user_favorite_teams` GATED)
4. `supabase/migrations/20260889_0001_age_access_profile_social_fields.sql` — mode-aware profile social-field lock

**Trust boundary:** Apple Declared Age Range is evaluated on-device. The server
receives only a client-asserted coarse status via
`record_user_age_access_result`. There is **no** cryptographic server verification
of Apple's response.

---

## 1. Create / link a staging project

```bash
# Create a new project in the Supabase dashboard (org > New project), e.g. fangeo-staging.
# Then, from the repo root — note the explicit --project-ref, never the production ref:

supabase link --project-ref <STAGING_PROJECT_REF>

# Confirm which project is linked BEFORE anything else:
supabase projects list
cat supabase/.temp/project-ref   # must print the STAGING ref
```

If a staging project already exists, only run `supabase link --project-ref <STAGING_PROJECT_REF>`.

## 2. Compare local vs remote migration history

```bash
supabase migration list --linked
# Local-only rows will show for 20260886/20260887/20260888 (and any other unapplied).
# Verify NOTHING older is missing remotely before pushing; if history diverges, stop.
supabase db diff --linked --schema public | head -100   # sanity: unexpected drift check
```

## 3. Apply only the age-access migrations (staging)

Preferred (applies pending in order):

```bash
supabase db push --linked --dry-run    # review the plan; only 202608{86,87,88} should be pending beyond known items
supabase db push --linked
```

If other unrelated migrations are pending on staging and you need age-access only:

```bash
supabase db push --linked --include-all=false \
  --file supabase/migrations/20260886_0001_user_age_access.sql \
  --file supabase/migrations/20260887_0001_age_access_enforcement_core.sql \
  --file supabase/migrations/20260888_0001_age_access_social_write_triggers.sql
# (or apply each with psql "$STAGING_DB_URL" -f <file> and then
#  supabase migration repair --status applied <version> for history consistency)
```

## 4. Verify objects (SQL editor on staging)

```sql
-- Columns
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema='public' AND table_name='user_profiles'
  AND column_name IN ('age_access_status','age_policy_version','age_checked_at');

-- Functions + security definer + search_path
SELECT p.proname, p.prosecdef, p.proconfig
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public'
  AND p.proname IN ('age_access_allows_social','assert_age_access_allows_social',
                    'age_access_enforcement_mode','enforce_age_access_social_write',
                    'enforce_user_profiles_age_access_sticky_block',
                    'enforce_user_profiles_age_access_social_update');
-- Expect prosecdef = true and proconfig containing 'search_path=public' for each.

-- Grants
SELECT routine_name, grantee, privilege_type
FROM information_schema.routine_privileges
WHERE routine_schema='public'
  AND routine_name IN (
    'age_access_allows_social','assert_age_access_allows_social',
    'record_user_age_access_result','age_access_current_policy_version',
    'age_access_enforcement_mode'
  )
ORDER BY routine_name, grantee;
-- Expect: authenticated + service_role EXECUTE where granted;
-- record_user_age_access_result: authenticated ONLY (no service_role, no PUBLIC/anon).

-- Enforcement config
SELECT id, mode, current_policy_version FROM public.age_access_enforcement;
-- Expect: id=1, mode='block_under_13_only', current_policy_version='1'

-- Triggers attached
SELECT event_object_table, trigger_name, action_timing, event_manipulation
FROM information_schema.triggers
WHERE trigger_name IN (
  'trg_age_access_social_write',
  'trg_user_profiles_age_access_columns_freeze',
  'trg_user_profiles_age_access_sticky',
  'trg_user_profiles_age_access_social_update'
)
ORDER BY event_object_table, trigger_name, event_manipulation;
```

## 5. Seed test users (staging SQL editor, service role)

Create three auth users via the dashboard (or auth admin API), note their UUIDs,
then (service_role / postgres — direct UPDATE is intentional for seeding):

```sql
-- :eligible_uid, :blocked_uid, :unknown_uid, :stale_uid = auth user UUIDs with user_profiles rows
UPDATE public.user_profiles SET age_access_status='eligible',
  age_policy_version='1', age_checked_at=now() WHERE id = :'eligible_uid';
UPDATE public.user_profiles SET age_access_status='blocked_under_13',
  age_policy_version='1', age_checked_at=now() WHERE id = :'blocked_uid';
UPDATE public.user_profiles SET age_access_status='unknown',
  age_policy_version='1', age_checked_at=now() WHERE id = :'unknown_uid';
UPDATE public.user_profiles SET age_access_status='eligible',
  age_policy_version='0', age_checked_at=now() WHERE id = :'stale_uid';  -- stale policy
```

## 6. Copy-paste verification SQL (do not run against production)

```sql
-- ---------------------------------------------------------------------------
-- A) Client cannot directly set itself eligible
-- ---------------------------------------------------------------------------
BEGIN;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', :'unknown_uid', 'role', 'authenticated')::text, true);
SELECT set_config('role', 'authenticated', true);
UPDATE public.user_profiles
SET age_access_status='eligible', age_policy_version='1', age_checked_at=now()
WHERE id = :'unknown_uid';
-- expect: age_access_direct_write_denied
ROLLBACK;

-- ---------------------------------------------------------------------------
-- B) Guarded RPC records eligible correctly
-- ---------------------------------------------------------------------------
BEGIN;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', :'unknown_uid', 'role', 'authenticated')::text, true);
SELECT set_config('role', 'authenticated', true);
SELECT public.record_user_age_access_result('eligible');
SELECT age_access_status, age_policy_version, age_checked_at IS NOT NULL AS has_checked
FROM public.user_profiles WHERE id = :'unknown_uid';
-- expect: eligible / '1' / true
ROLLBACK;

-- ---------------------------------------------------------------------------
-- C) Blocked status is sticky (direct + RPC)
-- ---------------------------------------------------------------------------
BEGIN;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', :'blocked_uid', 'role', 'authenticated')::text, true);
SELECT set_config('role', 'authenticated', true);
UPDATE public.user_profiles SET age_access_status='eligible' WHERE id = :'blocked_uid';
-- expect: age_access_direct_write_denied (freeze) OR sticky if freeze bypassed
ROLLBACK;

BEGIN;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', :'blocked_uid', 'role', 'authenticated')::text, true);
SELECT set_config('role', 'authenticated', true);
SELECT public.record_user_age_access_result('eligible');
-- expect: age_access_blocked_status_sticky
ROLLBACK;

-- ---------------------------------------------------------------------------
-- D) Eligible current-policy user can perform social writes
-- ---------------------------------------------------------------------------
BEGIN;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', :'eligible_uid', 'role', 'authenticated')::text, true);
SELECT set_config('role', 'authenticated', true);
SELECT public.assert_age_access_allows_social();  -- succeeds
INSERT INTO public.friendships (requester_id, addressee_id, status)
VALUES (:'eligible_uid', :'unknown_uid', 'pending');  -- succeeds subject to RLS
ROLLBACK;

-- ---------------------------------------------------------------------------
-- E) Blocked user cannot perform social writes
-- ---------------------------------------------------------------------------
BEGIN;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', :'blocked_uid', 'role', 'authenticated')::text, true);
SELECT set_config('role', 'authenticated', true);
INSERT INTO public.friendships (requester_id, addressee_id, status)
VALUES (:'blocked_uid', :'eligible_uid', 'pending');
-- expect: age_access_blocked_under_13
ROLLBACK;

-- ---------------------------------------------------------------------------
-- F) Unknown user in block_under_13_only — allowed
-- ---------------------------------------------------------------------------
UPDATE public.age_access_enforcement
SET mode='block_under_13_only', updated_at=now() WHERE id=1;

BEGIN;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', :'unknown_uid', 'role', 'authenticated')::text, true);
SELECT set_config('role', 'authenticated', true);
SELECT public.age_access_allows_social();  -- expect true
ROLLBACK;

-- ---------------------------------------------------------------------------
-- G) Unknown user denied in require_eligible
-- ---------------------------------------------------------------------------
UPDATE public.age_access_enforcement
SET mode='require_eligible', updated_at=now() WHERE id=1;

BEGIN;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', :'unknown_uid', 'role', 'authenticated')::text, true);
SELECT set_config('role', 'authenticated', true);
SELECT public.assert_age_access_allows_social();
-- expect: age_access_unresolved
ROLLBACK;

-- ---------------------------------------------------------------------------
-- H) Stale-policy eligible user denied in require_eligible
-- ---------------------------------------------------------------------------
BEGIN;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', :'stale_uid', 'role', 'authenticated')::text, true);
SELECT set_config('role', 'authenticated', true);
SELECT public.assert_age_access_allows_social();
-- expect: age_access_unresolved  (status eligible but policy_version='0')
ROLLBACK;

-- ---------------------------------------------------------------------------
-- I) Unresolved user cannot edit social profile fields
-- ---------------------------------------------------------------------------
BEGIN;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', :'unknown_uid', 'role', 'authenticated')::text, true);
SELECT set_config('role', 'authenticated', true);
UPDATE public.user_profiles SET bio = 'trying' WHERE id = :'unknown_uid';
-- expect: age_access_unresolved (require_eligible still on)
ROLLBACK;

-- Age-only record path still works while unresolved:
BEGIN;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', :'unknown_uid', 'role', 'authenticated')::text, true);
SELECT set_config('role', 'authenticated', true);
SELECT public.record_user_age_access_result('unknown');  -- succeeds
ROLLBACK;

-- Restore rollout mode after strict tests
UPDATE public.age_access_enforcement
SET mode='block_under_13_only', updated_at=now() WHERE id=1;

-- ---------------------------------------------------------------------------
-- J) Safety / support / deletion / sign-out remain available (not age-gated)
-- ---------------------------------------------------------------------------
BEGIN;
SELECT set_config('request.jwt.claims',
  json_build_object('sub', :'blocked_uid', 'role', 'authenticated')::text, true);
SELECT set_config('role', 'authenticated', true);
-- Support / reports / blocked_users / DELETE — subject to normal RLS only.
-- Adjust column names to the live staging schema if they differ.
INSERT INTO public.support_requests (user_id, subject, body)
VALUES (:'blocked_uid', 'help', 'question');
INSERT INTO public.blocked_users (blocker_user_id, blocked_user_id)
VALUES (:'blocked_uid', :'eligible_uid');
DELETE FROM public.profile_pokes WHERE poker_user_id = :'blocked_uid';
ROLLBACK;

-- ---------------------------------------------------------------------------
-- K) service_role jobs remain operational
-- ---------------------------------------------------------------------------
BEGIN;
SELECT set_config('request.jwt.claims',
  json_build_object('role', 'service_role')::text, true);
SELECT set_config('role', 'service_role', true);
UPDATE public.user_profiles
SET age_access_status='eligible', age_policy_version='1', age_checked_at=now()
WHERE id = :'blocked_uid';  -- admin recovery OK
SELECT public.age_access_allows_social(:'blocked_uid');  -- expect true under service_role
ROLLBACK;
-- Re-seed blocked_uid after this test if needed.
```

Adjust column lists to the actual staging schema where they differ; the intent
of each test is fixed.

## 7. Table audit (required vs optional)

| Table | Class | Trigger | Reason |
|---|---|---|---|
| friendships | required | yes | Core friend graph |
| profile_pokes | required | yes | Social poke |
| direct_conversations | required | yes | Core DM |
| direct_messages | required | yes | Core DM |
| group_conversations | required | yes | Group chat |
| group_conversation_members | required | yes | Group membership |
| group_conversation_invitations | required | yes | Group invites |
| group_messages | required | yes | Group messages |
| pickup_games | required | yes | Pickup create/edit |
| pickup_game_requests | required | yes | Pickup join |
| pickup_game_invites | required | yes | Pickup invites |
| pickup_game_creator_ratings | required | yes | Ratings |
| venue_event_comments | required | yes | Venue UGC |
| venue_event_comment_likes | required | yes | Venue UGC |
| venue_event_vibes | required | yes | Venue vibes |
| venue_event_interests | required | yes | Going interests |
| venue_ratings | required | yes | Venue ratings |
| user_favorite_teams | required | yes | **GATED** — profile personalization |
| pro_game_predictions | required | yes | Predictions |
| saved_pro_games | required | yes | Saved pro games |
| profile_likes | optional | if present | Feature table |
| venue_event_comment_reactions | optional | if present | Feature table |
| venue_event_predictions | optional | if present | Feature table |
| pro_game_alert_subscriptions | optional | if present | Feature table |

**Decision:** `user_favorite_teams` writes are gated; reads are not. Comments and SQL agree.

## 8. Entitlement validation on a built app

```bash
codesign -d --entitlements :- "/path/to/GameOn.app"
```

Expected to contain:

```xml
<key>com.apple.developer.declared-age-range</key>
<true/>
```

(A provisioning profile that includes the Declared Age Range capability is
required for signed device builds; unsigned simulator builds do not prove the
entitlement.)
