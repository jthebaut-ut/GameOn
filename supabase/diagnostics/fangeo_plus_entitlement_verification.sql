-- Read-only FanGeo+ / privileged user_profiles entitlement verification.
-- Covers protections from migrations 20260865 + 20260872.
-- Run in Supabase SQL Editor. Does not mutate data.

-- =============================================================================
-- 1) Triggers 65 / 72 present on user_profiles
-- =============================================================================
-- Expect:
--   trg_user_profiles_privileged_columns   (20260865 UPDATE freeze)
--   trg_user_profiles_privileged_insert    (20260872 INSERT defaults)
SELECT
  t.tgname AS trigger_name,
  pg_get_triggerdef(t.oid, true) AS trigger_def,
  CASE
    WHEN t.tgname = 'trg_user_profiles_privileged_columns' THEN '20260865'
    WHEN t.tgname = 'trg_user_profiles_privileged_insert' THEN '20260872'
    ELSE 'other'
  END AS expected_migration
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname = 'user_profiles'
  AND NOT t.tgisinternal
  AND t.tgname IN (
    'trg_user_profiles_privileged_columns',
    'trg_user_profiles_privileged_insert'
  )
ORDER BY t.tgname;

-- Missing-trigger summary (expect both rows true)
SELECT
  EXISTS (
    SELECT 1
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'user_profiles'
      AND NOT t.tgisinternal
      AND t.tgname = 'trg_user_profiles_privileged_columns'
  ) AS has_65_update_trigger,
  EXISTS (
    SELECT 1
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'user_profiles'
      AND NOT t.tgisinternal
      AND t.tgname = 'trg_user_profiles_privileged_insert'
  ) AS has_72_insert_trigger;

-- =============================================================================
-- 2) Guard function bodies mention FanGeo+ columns / GUC bypass
-- =============================================================================
SELECT
  (pg_get_functiondef('public.enforce_user_profiles_privileged_columns()'::regprocedure)
    ILIKE '%ad_free_enabled%') AS update_guards_ad_free_enabled,
  (pg_get_functiondef('public.enforce_user_profiles_privileged_columns()'::regprocedure)
    ILIKE '%ad_free_expires_at%') AS update_guards_ad_free_expires_at,
  (pg_get_functiondef('public.enforce_user_profiles_privileged_columns()'::regprocedure)
    ILIKE '%gameon.user_profiles_privileged_write%') AS update_has_privileged_write_guc,
  (pg_get_functiondef('public.enforce_user_profiles_privileged_insert_defaults()'::regprocedure)
    ILIKE '%ad_free_enabled := false%') AS insert_forces_ad_free_off;

-- =============================================================================
-- 3) Client EXECUTE revoked on sensitive helpers; admin grant intact
-- =============================================================================
SELECT
  p.proname,
  pg_get_function_identity_arguments(p.oid) AS args,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_execute,
  has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_execute,
  has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_role_execute
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND (
    (p.proname = 'queue_fangeo_plus_award_push_notification'
      AND pg_get_function_identity_arguments(p.oid) = 'uuid')
    OR (p.proname = 'admin_set_user_fangeo_plus')
    OR (p.proname = 'gameon_account_deletion_soft_delete_core')
    OR (p.proname = 'is_support_inbox_admin')
  )
ORDER BY p.proname, args;
-- Expect:
--   queue_fangeo_plus_award_push_notification: authenticated=false, service_role=true
--   gameon_account_deletion_soft_delete_core: authenticated=false (if present)
--   admin_set_user_fangeo_plus: authenticated=true (admin JWT gated inside)
--   is_support_inbox_admin: authenticated=true

-- =============================================================================
-- 4) Table privileges on user_profiles (72 hardens anon / DELETE)
-- =============================================================================
SELECT
  grantee,
  privilege_type
FROM information_schema.role_table_grants
WHERE table_schema = 'public'
  AND table_name = 'user_profiles'
  AND grantee IN ('anon', 'authenticated', 'service_role')
ORDER BY grantee, privilege_type;
-- Expect after 72: anon typically none; authenticated without DELETE/TRUNCATE;
-- service_role ALL (or broad).

-- =============================================================================
-- 5) FanGeo+ column comments / presence (no value inspection of PII beyond counts)
-- =============================================================================
SELECT
  c.column_name,
  c.data_type,
  c.is_nullable
FROM information_schema.columns c
WHERE c.table_schema = 'public'
  AND c.table_name = 'user_profiles'
  AND c.column_name IN ('ad_free_enabled', 'ad_free_expires_at')
ORDER BY c.column_name;

SELECT
  count(*) FILTER (WHERE ad_free_enabled) AS plus_users,
  count(*) FILTER (WHERE NOT coalesce(ad_free_enabled, false)) AS regular_or_null_off,
  count(*) AS total_profiles
FROM public.user_profiles;
-- Counts should be unchanged by applying 65/72 (protections only).

-- =============================================================================
-- 6) admin_set_user_fangeo_plus auth: p_admin_email ignored?
-- =============================================================================
SELECT
  (pg_get_functiondef(
     'public.admin_set_user_fangeo_plus(uuid, boolean, text, timestamptz, text)'::regprocedure
   ) ILIKE '%is_support_inbox_admin()%') AS uses_jwt_admin_gate,
  (pg_get_functiondef(
     'public.admin_set_user_fangeo_plus(uuid, boolean, text, timestamptz, text)'::regprocedure
   ) ILIKE '%user_profiles_privileged_write%') AS sets_privileged_write_guc;
