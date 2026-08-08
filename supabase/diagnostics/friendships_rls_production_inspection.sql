-- Read-only inspection for public.friendships RLS / grants / mutation RPCs.
-- Run in Supabase SQL Editor against the target project. Does not mutate data.
-- Companion migration: 20260915_0002_friendships_rls.sql

-- 1) RLS enabled / forced?
SELECT
  n.nspname AS schema,
  c.relname AS table,
  c.relrowsecurity AS rls_enabled,
  c.relforcerowsecurity AS rls_forced
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname = 'friendships';

-- 2) Policies (expect SELECT involving me only; no INSERT/UPDATE/DELETE for authenticated)
SELECT
  schemaname,
  tablename,
  policyname,
  permissive,
  roles,
  cmd AS command,
  qual AS using_expression,
  with_check
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename = 'friendships'
ORDER BY policyname, cmd;

-- 3) Table privileges
SELECT
  grantee,
  privilege_type
FROM information_schema.role_table_grants
WHERE table_schema = 'public'
  AND table_name = 'friendships'
  AND grantee IN ('anon', 'authenticated', 'service_role', 'PUBLIC')
ORDER BY grantee, privilege_type;

-- 4) Key mutation RPCs present + EXECUTE grants
SELECT
  p.proname AS function_name,
  pg_get_function_identity_arguments(p.oid) AS args,
  p.prosecdef AS security_definer,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_execute,
  has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_execute,
  has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_role_execute
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN (
    'friendship_ensure_pending',
    'accept_friend_request',
    'decline_friend_request',
    'cancel_outgoing_friend_request',
    'remove_friend',
    'friendship_ensure_pending_to_business'
  )
ORDER BY p.proname, args;

-- 5) accept_friend_request body includes blocked_users check?
SELECT
  (pg_get_functiondef('public.accept_friend_request(uuid)'::regprocedure)
    ILIKE '%blocked_users%') AS accept_checks_blocks,
  (pg_get_functiondef('public.friendship_ensure_pending(uuid)'::regprocedure)
    ILIKE '%blocked_users%') AS ensure_pending_checks_blocks;

-- 6) Optional: sample policy USING text for friendships_select_involving_me
SELECT
  policyname,
  cmd,
  qual
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename = 'friendships'
  AND policyname = 'friendships_select_involving_me';
