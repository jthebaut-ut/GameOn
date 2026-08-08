-- =============================================================================
-- chat_global_search_security_review_checks.sql
-- Manual / staging verification for 20260918_0001 (privilege + privacy probes).
-- Do NOT run automatically against production as part of apply.
--
-- Runtime matrix A–L requires seeded fixtures; this file covers static / privilege
-- checks plus preview privacy unit probes that do not need live chat data.
-- =============================================================================

-- M. Internal helpers privilege matrix
-- chat_search_safe_message_preview(text) MUST be executable by authenticated:
--   expression indexes on direct_messages / group_messages evaluate it as the
--   inserting role (legacy PostgREST INSERT). See 20260919_0001.
-- Other search helpers remain non-executable by authenticated.
DO $$
BEGIN
  IF NOT has_function_privilege(
    'authenticated',
    'public.chat_search_safe_message_preview(text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL M: authenticated missing EXECUTE on chat_search_safe_message_preview (required for expression-index INSERT)';
  END IF;
  IF has_function_privilege(
    'anon',
    'public.chat_search_safe_message_preview(text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL M: anon can execute chat_search_safe_message_preview';
  END IF;
  IF has_function_privilege(
    'authenticated',
    'public.chat_search_normalize_query(text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL M: authenticated can execute chat_search_normalize_query';
  END IF;
  IF has_function_privilege(
    'authenticated',
    'public.chat_search_viewer_can_read_direct_message(uuid,uuid,timestamptz,timestamptz,boolean,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL M: authenticated can execute chat_search_viewer_can_read_direct_message';
  END IF;
  IF has_function_privilege(
    'authenticated',
    'public.chat_search_viewer_can_read_group_message(uuid,uuid,text,timestamptz,timestamptz,boolean,uuid,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL M: authenticated can execute chat_search_viewer_can_read_group_message';
  END IF;
  IF has_function_privilege(
    'authenticated',
    'public.chat_search_viewer_can_access_conversation(uuid,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL M: authenticated can execute chat_search_viewer_can_access_conversation';
  END IF;
  RAISE NOTICE 'PASS M: safe_preview executable by authenticated for indexes; other helpers locked';
END $$;

-- Public RPCs: authenticated yes, anon no
DO $$
BEGIN
  IF NOT has_function_privilege(
    'authenticated',
    'public.search_chat_conversations(text,integer)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: authenticated missing search_chat_conversations';
  END IF;
  IF NOT has_function_privilege(
    'authenticated',
    'public.search_chat_messages(text,uuid,integer)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: authenticated missing search_chat_messages';
  END IF;
  IF has_function_privilege(
    'anon',
    'public.search_chat_messages(text,uuid,integer)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: anon can execute search_chat_messages';
  END IF;
  IF has_function_privilege(
    'anon',
    'public.search_chat_conversations(text,integer)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: anon can execute search_chat_conversations';
  END IF;
  RAISE NOTICE 'PASS: public search RPCs granted only to authenticated (+ service_role)';
END $$;

-- Alias wrappers must be SECURITY INVOKER (prosecdef = false)
DO $$
DECLARE
  v_direct boolean;
  v_group boolean;
  v_core boolean;
BEGIN
  SELECT p.prosecdef INTO v_direct
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'search_direct_messages'
    AND pg_get_function_identity_arguments(p.oid) = 'p_query text, p_limit integer';

  SELECT p.prosecdef INTO v_group
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'search_group_messages'
    AND pg_get_function_identity_arguments(p.oid) = 'p_query text, p_limit integer';

  SELECT p.prosecdef INTO v_core
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'search_chat_messages'
    AND pg_get_function_identity_arguments(p.oid) = 'p_query text, p_conversation_id uuid, p_limit integer';

  IF v_direct IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL: search_direct_messages expected SECURITY INVOKER';
  END IF;
  IF v_group IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL: search_group_messages expected SECURITY INVOKER';
  END IF;
  IF v_core IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL: search_chat_messages expected SECURITY DEFINER';
  END IF;
  RAISE NOTICE 'PASS: DEFINER core + INVOKER aliases';
END $$;

-- J / K preview privacy (service_role / postgres can call internal helper)
DO $$
DECLARE
  v text;
BEGIN
  v := public.chat_search_safe_message_preview(
    '__FG_LOCATION_SHARE_V1__{"latitude":40.7,"longitude":-74.0}'
  );
  IF v IS DISTINCT FROM 'Shared a location' OR position('40.7' in v) > 0 THEN
    RAISE EXCEPTION 'FAIL J: location preview leaked coords (%)', v;
  END IF;

  v := public.chat_search_safe_message_preview(
    '__FG_POLL_V1__{"poll_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","voters":["u1"]}'
  );
  IF v IS DISTINCT FROM 'Created a poll'
     OR position('aaaaaaaa' in v) > 0
     OR position('voters' in v) > 0 THEN
    RAISE EXCEPTION 'FAIL K: poll preview leaked identity/payload (%)', v;
  END IF;

  v := public.chat_search_safe_message_preview(
    '__FG_UNKNOWN_V9__{"lat":1,"lng":2,"secret":"x"}'
  );
  IF v IS DISTINCT FROM 'Shared content'
     OR position('lat' in v) > 0
     OR position('secret' in v) > 0 THEN
    RAISE EXCEPTION 'FAIL: unrecognized sentinel fell through to raw (%)', v;
  END IF;

  RAISE NOTICE 'PASS J/K: structured previews are safe labels only';
END $$;

-- Query normalization bounds
DO $$
BEGIN
  IF public.chat_search_normalize_query('a') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: min length 2 not enforced';
  END IF;
  IF public.chat_search_normalize_query(repeat('x', 150)) IS DISTINCT FROM repeat('x', 100) THEN
    RAISE EXCEPTION 'FAIL: max length 100 not enforced';
  END IF;
  IF public.chat_search_normalize_query(E'he\x00llo') IS DISTINCT FROM 'hello' THEN
    RAISE EXCEPTION 'FAIL: control-char scrub missing';
  END IF;
  RAISE NOTICE 'PASS: query normalize min/max/control scrub';
END $$;

-- Trigram indexes exist on safe-preview expressions
DO $$
BEGIN
  IF to_regclass('public.direct_messages_safe_preview_trgm_idx') IS NULL THEN
    RAISE EXCEPTION 'FAIL: missing direct_messages_safe_preview_trgm_idx';
  END IF;
  IF to_regclass('public.group_messages_safe_preview_trgm_idx') IS NULL THEN
    RAISE EXCEPTION 'FAIL: missing group_messages_safe_preview_trgm_idx';
  END IF;
  RAISE NOTICE 'PASS: privacy-safe trgm indexes present';
END $$;

/*
------------------------------------------------------------------------------
Runtime matrix (seed fixtures; run as each auth.uid()):

A. User searches own sent DM → returned
B. User searches peer message in own DM → returned
C. User guesses unrelated DM UUID as p_conversation_id → zero rows (no error)
D. Removed group member → only membership-window rows; nothing outside window
E. Pending pickup player → zero rows (is_pickup_game_chat_authorized false)
F. Cleared history → clearer cannot search pre-clear messages
G. Other participant who did not clear → still finds those messages
H. Blocked-user restrictions match pickup_invite_users_are_unblocked /
   group_viewer_can_see_sender_message (own sent still searchable)
I. deleted_at / is_deleted set → original text absent from search
J. Location payload → safe label only (see probe above)
K. Anonymous poll → no voter identity (see probe above)
L. Account switch → auth.uid() isolates results (no prior-user leakage)
M. Direct helper execution by authenticated → denied (see probe above)
------------------------------------------------------------------------------
*/
