-- =============================================================================
-- READ-ONLY diagnostic: legacy direct_messages INSERT → 42501 on
-- public.chat_search_safe_message_preview(text)
-- =============================================================================
-- Investigation only. Do NOT GRANT/REVOKE/ALTER from this file.
-- Run in SQL editor / psql against staging or production.
--
-- Confirmed client symptom (physical device):
--   PostgrestError.code=42501
--   PostgrestError.message=permission denied for function chat_search_safe_message_preview
--
-- Detection note:
--   pg_get_function_identity_arguments() may return "p_body text".
--   regprocedure / to_regprocedure form is:
--     public.chat_search_safe_message_preview(text)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0) Resolve exact (text) overload OID (correct detection)
-- ---------------------------------------------------------------------------
WITH resolved AS (
  SELECT
    coalesce(
      to_regprocedure('public.chat_search_safe_message_preview(text)'),
      (
        SELECT p.oid
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'chat_search_safe_message_preview'
          AND p.pronargs = 1
          AND (p.proargtypes::oid[])[1] = 'text'::regtype::oid
        LIMIT 1
      )
    ) AS func_oid
)
SELECT
  r.func_oid,
  CASE
    WHEN r.func_oid IS NULL THEN NULL
    ELSE format(
      '%I.%I(%s)',
      n.nspname,
      p.proname,
      pg_get_function_identity_arguments(p.oid)
    )
  END AS exact_signature_display,
  CASE
    WHEN r.func_oid IS NULL THEN NULL
    ELSE 'public.chat_search_safe_message_preview(text)'
  END AS regprocedure_form,
  n.nspname AS schema_name,
  pg_get_function_identity_arguments(p.oid) AS identity_arguments,
  pg_get_function_result(p.oid) AS return_type,
  pg_get_userbyid(p.proowner) AS owner,
  p.prosecdef AS security_definer,
  p.provolatile AS volatility_char,
  CASE p.provolatile
    WHEN 'i' THEN 'immutable'
    WHEN 's' THEN 'stable'
    WHEN 'v' THEN 'volatile'
  END AS volatility,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_can_execute,
  has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_can_execute,
  has_function_privilege('public', p.oid, 'EXECUTE') AS public_can_execute
FROM resolved r
LEFT JOIN pg_proc p ON p.oid = r.func_oid
LEFT JOIN pg_namespace n ON n.oid = p.pronamespace;

-- ---------------------------------------------------------------------------
-- 1) All overloads (expect a single public text-arg function)
-- ---------------------------------------------------------------------------
SELECT
  n.nspname AS schema_name,
  p.proname,
  p.oid,
  pg_get_function_identity_arguments(p.oid) AS identity_arguments,
  pg_get_function_arguments(p.oid) AS full_arguments,
  pg_get_function_result(p.oid) AS return_type,
  p.pronargs,
  (p.proargtypes::oid[])[1]::regtype AS arg0_type,
  pg_get_userbyid(p.proowner) AS owner,
  p.prosecdef AS security_definer,
  p.proconfig AS proconfig_search_path,
  p.proacl::text AS acl,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_can_execute,
  has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_can_execute,
  has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_role_can_execute,
  has_function_privilege('postgres', p.oid, 'EXECUTE') AS postgres_can_execute
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = 'chat_search_safe_message_preview'
ORDER BY identity_arguments;

-- ---------------------------------------------------------------------------
-- 2) Expression indexes that invoke the helper (INSERT/UPDATE evaluation path)
-- ---------------------------------------------------------------------------
SELECT
  c.relname AS table_name,
  i.relname AS index_name,
  to_regclass(format('%I.%I', n.nspname, i.relname)) IS NOT NULL AS exists_via_regclass,
  pg_get_indexdef(x.indexrelid) AS index_def,
  x.indisvalid AS is_valid,
  x.indisready AS is_ready
FROM pg_index x
JOIN pg_class i ON i.oid = x.indexrelid
JOIN pg_class c ON c.oid = x.indrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND (
    i.relname IN (
      'direct_messages_safe_preview_trgm_idx',
      'group_messages_safe_preview_trgm_idx'
    )
    OR pg_get_indexdef(x.indexrelid) ILIKE '%chat_search_safe_message_preview%'
  )
ORDER BY c.relname, i.relname;

SELECT
  to_regclass('public.direct_messages_safe_preview_trgm_idx') AS direct_messages_safe_preview_trgm_idx,
  to_regclass('public.group_messages_safe_preview_trgm_idx') AS group_messages_safe_preview_trgm_idx;

-- ---------------------------------------------------------------------------
-- 3) Triggers on direct_messages (for completeness — not expected to call preview)
-- ---------------------------------------------------------------------------
SELECT
  t.tgname AS trigger_name,
  CASE t.tgtype & 2 WHEN 2 THEN 'BEFORE' ELSE 'AFTER' END AS timing,
  trim(
    BOTH ' '
    FROM concat_ws(
      ' ',
      CASE WHEN t.tgtype & 4  = 4  THEN 'INSERT' END,
      CASE WHEN t.tgtype & 8  = 8  THEN 'DELETE' END,
      CASE WHEN t.tgtype & 16 = 16 THEN 'UPDATE' END
    )
  ) AS events,
  t.tgenabled AS enabled,
  p.proname AS trigger_function,
  pg_get_userbyid(p.proowner) AS trigger_function_owner,
  p.prosecdef AS trigger_function_security_definer,
  p.proconfig AS trigger_function_proconfig,
  pg_get_triggerdef(t.oid, true) AS trigger_def
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_proc p ON p.oid = t.tgfoid
WHERE n.nspname = 'public'
  AND c.relname = 'direct_messages'
  AND NOT t.tgisinternal
ORDER BY t.tgname;

-- ---------------------------------------------------------------------------
-- 4) send_direct_message overloads (RPC path — should remain executable)
-- ---------------------------------------------------------------------------
SELECT
  pg_get_function_identity_arguments(p.oid) AS identity_arguments,
  pg_get_userbyid(p.proowner) AS owner,
  p.prosecdef AS security_definer,
  p.proconfig AS proconfig,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_can_execute,
  has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_can_execute
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = 'send_direct_message'
ORDER BY identity_arguments;

-- ---------------------------------------------------------------------------
-- 5) Table INSERT privilege + INSERT policies (must remain strict)
-- ---------------------------------------------------------------------------
SELECT
  has_table_privilege('authenticated', 'public.direct_messages', 'INSERT')
    AS authenticated_can_insert_direct_messages;

SELECT
  policyname,
  cmd,
  roles,
  qual,
  with_check
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename = 'direct_messages'
  AND cmd = 'INSERT'
ORDER BY policyname;

SELECT
  EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'direct_messages'
      AND cmd = 'INSERT'
      AND (
        coalesce(with_check, '') ILIKE '%direct_message_send_allowed%'
        OR coalesce(qual, '') ILIKE '%direct_message_send_allowed%'
      )
  ) AS insert_policy_references_direct_message_send_allowed;

-- ---------------------------------------------------------------------------
-- 6) Interpretation checklist (manual)
-- ---------------------------------------------------------------------------
-- IF resolved OID exists
--   AND authenticated_can_execute = false
--   AND both safe-preview expression indexes exist
--   → legacy PostgREST INSERT as authenticated fails with SQLSTATE 42501
--     while evaluating the expression index.
--
-- IF send_direct_message is SECURITY DEFINER and owner can execute the helper
--   → new RPC clients succeed even while authenticated lacks EXECUTE.
--
-- Fix: apply repaired 20260919_0001 (GRANT EXECUTE TO authenticated only).
-- Do not rerun 20260918. Do not weaken direct_message_send_allowed / INSERT RLS.
