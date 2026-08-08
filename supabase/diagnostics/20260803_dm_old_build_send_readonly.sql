-- =============================================================================
-- READ-ONLY diagnostic: old FanGeo DM send vs RPC-only production
-- =============================================================================
-- Investigation only. Do NOT apply grants/revokes/policy changes from this file.
-- Run in SQL editor / psql against the production (or staging) database.
-- =============================================================================

-- 1) Can authenticated still INSERT into direct_messages?
SELECT
  has_table_privilege(
    'authenticated',
    'public.direct_messages',
    'INSERT'
  ) AS authenticated_can_insert_direct_messages,
  has_table_privilege(
    'authenticated',
    'public.direct_messages',
    'SELECT'
  ) AS authenticated_can_select_direct_messages;

-- 2) Table grants
SELECT
  grantee,
  privilege_type
FROM information_schema.role_table_grants
WHERE table_schema = 'public'
  AND table_name = 'direct_messages'
ORDER BY grantee, privilege_type;

-- 3) Active RLS policies on direct_messages
SELECT
  schemaname,
  tablename,
  policyname,
  roles,
  cmd,
  qual,
  with_check
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename = 'direct_messages'
ORDER BY policyname;

-- 4) send_direct_message overloads
SELECT
  n.nspname AS schema_name,
  p.proname,
  pg_get_function_identity_arguments(p.oid) AS identity_arguments,
  pg_get_function_arguments(p.oid) AS full_arguments,
  pg_get_function_result(p.oid) AS return_type,
  p.prosecdef AS security_definer,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_can_execute
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = 'send_direct_message'
ORDER BY identity_arguments;

-- 5) Function grants (EXECUTE) for send_direct_message
SELECT
  p.proname,
  pg_get_function_identity_arguments(p.oid) AS identity_arguments,
  r.rolname AS grantee,
  has_function_privilege(r.oid, p.oid, 'EXECUTE') AS can_execute
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
CROSS JOIN pg_roles r
WHERE n.nspname = 'public'
  AND p.proname = 'send_direct_message'
  AND r.rolname IN ('anon', 'authenticated', 'service_role', 'postgres')
ORDER BY identity_arguments, grantee;

-- 6) Interpretation checklist (manual)
-- IF authenticated_can_insert_direct_messages = false
--   → Phase B (20260915_0005b) applied; old PostgREST INSERT clients fail for ALL recipients
--     with privilege denial (typically SQLSTATE 42501 / permission denied for table).
-- IF authenticated_can_insert = true AND no INSERT policy
--   → RLS denies all INSERTs (WITH CHECK missing).
-- IF authenticated_can_insert = true AND INSERT policy uses direct_message_send_allowed
--   → Old INSERT still possible; per-conversation friendship/block/eligibility gates apply
--     (would NOT fail for "every" accepted friend unless send_allowed is broken).
-- IF send_direct_message exists with (uuid, text, uuid DEFAULT NULL) and EXECUTE for authenticated
--   → New RPC clients succeed; old INSERT-only clients still fail after Phase B.
-- =============================================================================
