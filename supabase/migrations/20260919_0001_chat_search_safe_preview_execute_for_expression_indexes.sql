-- =============================================================================
-- 20260919_0001 — Grant EXECUTE on chat_search_safe_message_preview for index
-- =============================================================================
-- PROBLEM (confirmed physical-device PostgREST):
--   Legacy clients INSERT into public.direct_messages as role `authenticated`.
--   Migration 20260918_0001 created expression index
--     public.direct_messages_safe_preview_trgm_idx
--   using public.chat_search_safe_message_preview(body), then REVOKED EXECUTE
--   from authenticated (intentionally treating the helper as "internal").
--
--   PostgreSQL evaluates expression-index functions as the inserting role.
--   Result: SQLSTATE 42501
--     permission denied for function chat_search_safe_message_preview
--
--   New clients using SECURITY DEFINER send_direct_message were unaffected
--   because index maintenance runs as the definer owner (who retained EXECUTE).
--
-- FIX (minimal, secure):
--   GRANT EXECUTE on the exact IMMUTABLE signature (text) to authenticated.
--   Keep anon / PUBLIC revoked.
--   Do NOT change function body, owner, SECURITY mode, volatility, indexes,
--   search RPCs, direct_messages RLS, or direct_message_send_allowed.
--
-- Function detection note:
--   Live pg_get_function_identity_arguments() returns "p_body text".
--   regprocedure form is public.chat_search_safe_message_preview(text).
--   Resolve via to_regprocedure('(text)') / OID — never require identity
--   arguments to equal the literal string "text".
--
-- Do NOT apply from the agent; review and apply deliberately.
-- =============================================================================

DO $$
DECLARE
  v_oid oid;
  v_idx_dm regclass;
  v_idx_gm regclass;
BEGIN
  -- Prefer type-only regprocedure form (not named-argument identity string).
  v_oid := to_regprocedure('public.chat_search_safe_message_preview(text)');

  -- Fallback: single public overload whose sole argument type is text
  -- (identity may display as "p_body text" or "text").
  IF v_oid IS NULL THEN
    SELECT p.oid
    INTO v_oid
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'chat_search_safe_message_preview'
      AND p.pronargs = 1
      AND (p.proargtypes::oid[])[1] = 'text'::regtype::oid;
  END IF;

  IF v_oid IS NULL THEN
    RAISE EXCEPTION
      'public.chat_search_safe_message_preview(text) not found — apply 20260918_0001 first';
  END IF;

  -- Confirm we resolved the text-arg helper (OID retained for privilege checks).
  IF NOT (
    SELECT p.pronargs = 1
       AND (p.proargtypes::oid[])[1] = 'text'::regtype::oid
    FROM pg_proc p
    WHERE p.oid = v_oid
  ) THEN
    RAISE EXCEPTION
      'Resolved chat_search_safe_message_preview OID % is not the (text) overload',
      v_oid;
  END IF;

  v_idx_dm := to_regclass('public.direct_messages_safe_preview_trgm_idx');
  v_idx_gm := to_regclass('public.group_messages_safe_preview_trgm_idx');

  IF v_idx_dm IS NULL THEN
    RAISE EXCEPTION
      'Missing expression index public.direct_messages_safe_preview_trgm_idx';
  END IF;
  IF v_idx_gm IS NULL THEN
    RAISE EXCEPTION
      'Missing expression index public.group_messages_safe_preview_trgm_idx';
  END IF;

  -- Transaction-local OID for postcondition block.
  PERFORM set_config('fangeo.chat_search_safe_preview_oid', v_oid::text, true);

  RAISE NOTICE
    'Resolved chat_search_safe_message_preview OID=% identity=%',
    v_oid,
    pg_get_function_identity_arguments(v_oid);
END $$;

REVOKE ALL ON FUNCTION public.chat_search_safe_message_preview(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.chat_search_safe_message_preview(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.chat_search_safe_message_preview(text) TO authenticated;

DO $$
DECLARE
  v_oid oid;
  v_prosecdef boolean;
  v_provolatile "char";
BEGIN
  v_oid := nullif(current_setting('fangeo.chat_search_safe_preview_oid', true), '')::oid;
  IF v_oid IS NULL THEN
    v_oid := to_regprocedure('public.chat_search_safe_message_preview(text)');
  END IF;
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'FAIL: could not resolve chat_search_safe_message_preview(text) OID after grant';
  END IF;

  SELECT p.prosecdef, p.provolatile
  INTO v_prosecdef, v_provolatile
  FROM pg_proc p
  WHERE p.oid = v_oid;

  IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: authenticated missing EXECUTE on chat_search_safe_message_preview OID %', v_oid;
  END IF;

  IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: anon must not EXECUTE chat_search_safe_message_preview OID %', v_oid;
  END IF;

  -- PUBLIC role must not retain EXECUTE (ACL may omit PUBLIC entirely after REVOKE ALL).
  IF has_function_privilege('public', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: PUBLIC must not EXECUTE chat_search_safe_message_preview OID %', v_oid;
  END IF;

  IF v_prosecdef IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL: function must remain SECURITY INVOKER (prosecdef=false)';
  END IF;

  IF v_provolatile IS DISTINCT FROM 'i' THEN
    RAISE EXCEPTION 'FAIL: function must remain IMMUTABLE (provolatile=i)';
  END IF;

  IF to_regclass('public.direct_messages_safe_preview_trgm_idx') IS NULL THEN
    RAISE EXCEPTION 'FAIL: direct_messages_safe_preview_trgm_idx missing after grant';
  END IF;
  IF to_regclass('public.group_messages_safe_preview_trgm_idx') IS NULL THEN
    RAISE EXCEPTION 'FAIL: group_messages_safe_preview_trgm_idx missing after grant';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'direct_messages'
      AND cmd = 'INSERT'
      AND (
        coalesce(with_check, '') ILIKE '%direct_message_send_allowed%'
        OR coalesce(qual, '') ILIKE '%direct_message_send_allowed%'
      )
  ) THEN
    RAISE EXCEPTION
      'FAIL: direct_messages INSERT RLS no longer references direct_message_send_allowed';
  END IF;

  RAISE NOTICE
    'PASS: authenticated EXECUTE on OID=%; anon/PUBLIC denied; IMMUTABLE INVOKER; indexes+RLS intact',
    v_oid;
END $$;
