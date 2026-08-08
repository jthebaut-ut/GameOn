-- =============================================================================
-- READ-ONLY post-fix verification for 20260919_0001
-- chat_search_safe_message_preview EXECUTE (expression-index INSERT fix)
-- =============================================================================
-- Do NOT apply grants from this file. Run after 20260919_0001 is applied.
--
-- Detection note:
--   Resolve via to_regprocedure('public.chat_search_safe_message_preview(text)')
--   or OID + pronargs/proargtypes. Do not require identity_arguments = 'text'
--   (live display is often "p_body text").
-- =============================================================================

-- 0) Resolve OID once
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
  pg_get_function_identity_arguments(p.oid) AS identity_arguments,
  pg_get_userbyid(p.proowner) AS owner,
  p.prosecdef AS security_definer,
  CASE p.provolatile
    WHEN 'i' THEN 'immutable'
    WHEN 's' THEN 'stable'
    WHEN 'v' THEN 'volatile'
  END AS volatility,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_can_execute,
  has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_can_execute,
  has_function_privilege('public', p.oid, 'EXECUTE') AS public_can_execute,
  (p.prosecdef = false) AS remains_security_invoker,
  (p.provolatile = 'i') AS remains_immutable
FROM resolved r
LEFT JOIN pg_proc p ON p.oid = r.func_oid;

-- Expect after 20260919:
--   authenticated_can_execute = true
--   anon_can_execute = false
--   public_can_execute = false
--   remains_security_invoker = true
--   remains_immutable = true

-- 1) authenticated still has INSERT on direct_messages
SELECT
  has_table_privilege('authenticated', 'public.direct_messages', 'INSERT')
    AS authenticated_can_insert_direct_messages;

-- 2–3) Strict INSERT RLS policy still present and references send_allowed
SELECT
  policyname,
  cmd,
  roles,
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

-- 4) Sibling helpers must remain locked (OID-based)
SELECT
  p.proname,
  p.oid,
  pg_get_function_identity_arguments(p.oid) AS identity_arguments,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_can_execute,
  has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_can_execute
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN (
    'chat_search_normalize_query',
    'chat_search_viewer_can_read_direct_message',
    'chat_search_viewer_can_read_group_message',
    'chat_search_viewer_can_access_conversation'
  )
ORDER BY p.proname, identity_arguments;

-- 5) send_direct_message remains executable by authenticated
SELECT
  p.oid,
  pg_get_function_identity_arguments(p.oid) AS identity_arguments,
  p.prosecdef AS security_definer,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_can_execute,
  has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_can_execute
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = 'send_direct_message'
ORDER BY identity_arguments;

-- 6) Expression indexes still present
SELECT
  to_regclass('public.direct_messages_safe_preview_trgm_idx') AS direct_messages_safe_preview_trgm_idx,
  to_regclass('public.group_messages_safe_preview_trgm_idx') AS group_messages_safe_preview_trgm_idx;

SELECT
  c.relname AS table_name,
  i.relname AS index_name,
  x.indisvalid AS is_valid
FROM pg_index x
JOIN pg_class i ON i.oid = x.indexrelid
JOIN pg_class c ON c.oid = x.indrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND i.relname IN (
    'direct_messages_safe_preview_trgm_idx',
    'group_messages_safe_preview_trgm_idx'
  )
ORDER BY i.relname;

-- 7) Triggers remain installed/enabled (sample)
SELECT
  t.tgname,
  t.tgenabled,
  pg_get_triggerdef(t.oid, true) AS trigger_def
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname = 'direct_messages'
  AND NOT t.tgisinternal
ORDER BY t.tgname;

-- ---------------------------------------------------------------------------
-- Transaction-safe authenticated INSERT probe strategy (MANUAL — do not automate)
-- ---------------------------------------------------------------------------
-- Use a disposable test conversation you own. Prefer a staging database.
--
-- BEGIN;
--   -- As authenticated JWT / SET ROLE authenticated with a test uid claim:
--   -- INSERT INTO public.direct_messages (conversation_id, sender_id, body)
--   -- VALUES ('<test-conversation-uuid>', auth.uid(), 'fangeo_preview_perm_probe');
--   -- Expect: success (no 42501). Then ROLLBACK;
-- ROLLBACK;
--
-- Separately confirm RPC still works:
--   SELECT public.send_direct_message('<test-conversation-uuid>', 'fangeo_rpc_probe');
--
-- Do NOT leave probe rows in production.
