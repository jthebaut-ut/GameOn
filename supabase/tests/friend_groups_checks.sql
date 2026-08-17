-- Staging checks for Friend Groups (20260955 + hardening 20260959).
-- Manual / staging only. Do NOT run against production from the agent.
--
-- Covers: object presence, internal helper privilege hardening, client RPC grants,
-- and comments for behavioral matrix (create/members/unfriend/privacy).

DO $$
DECLARE
  v_src text;
  v_rpc text;
  v_rpcs text[] := ARRAY[
    'list_my_friend_groups',
    'create_friend_group',
    'rename_friend_group',
    'delete_friend_group',
    'list_friend_group_members',
    'set_friend_group_members',
    'set_friend_membership_in_groups',
    'list_my_friend_groups_containing_friend'
  ];
BEGIN
  IF to_regclass('public.friend_groups') IS NULL THEN
    RAISE EXCEPTION 'friend_groups missing — apply 20260955';
  END IF;
  IF to_regclass('public.friend_group_members') IS NULL THEN
    RAISE EXCEPTION 'friend_group_members missing — apply 20260955';
  END IF;

  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'set_friend_group_members'
  ORDER BY oid DESC
  LIMIT 1;
  IF v_src IS NULL OR position('friend_groups_users_are_accepted_friends' IN v_src) = 0 THEN
    RAISE EXCEPTION 'set_friend_group_members missing friend validation';
  END IF;

  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'create_friend_group'
  ORDER BY oid DESC
  LIMIT 1;
  IF v_src IS NULL OR position('friend_groups_normalize_name' IN v_src) = 0 THEN
    RAISE EXCEPTION 'create_friend_group missing normalize helper call';
  END IF;

  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE proname = 'friend_groups_cleanup_on_friendship_delete'
  ORDER BY oid DESC
  LIMIT 1;
  IF v_src IS NULL THEN
    RAISE EXCEPTION 'unfriend cleanup trigger function missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgname = 'trg_friend_groups_cleanup_on_friendship_delete'
  ) THEN
    RAISE EXCEPTION 'unfriend cleanup trigger missing';
  END IF;

  -- A–D: internal helpers must NOT be executable by authenticated / anon / PUBLIC.
  IF EXISTS (
    SELECT 1
    FROM information_schema.routine_privileges
    WHERE specific_schema = 'public'
      AND routine_name = 'friend_groups_users_are_accepted_friends'
      AND grantee IN ('authenticated', 'anon', 'PUBLIC')
      AND privilege_type = 'EXECUTE'
  ) THEN
    RAISE EXCEPTION
      'FAIL: friend_groups_users_are_accepted_friends still executable by client roles — apply 20260959';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.routine_privileges
    WHERE specific_schema = 'public'
      AND routine_name = 'friend_groups_normalize_name'
      AND grantee IN ('authenticated', 'anon', 'PUBLIC')
      AND privilege_type = 'EXECUTE'
  ) THEN
    RAISE EXCEPTION
      'FAIL: friend_groups_normalize_name still executable by client roles — apply 20260959';
  END IF;

  -- E: client-facing RPCs remain executable by authenticated.
  FOREACH v_rpc IN ARRAY v_rpcs LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM information_schema.routine_privileges
      WHERE specific_schema = 'public'
        AND routine_name = v_rpc
        AND grantee = 'authenticated'
        AND privilege_type = 'EXECUTE'
    ) THEN
      RAISE EXCEPTION 'FAIL: authenticated missing EXECUTE on %', v_rpc;
    END IF;

    IF EXISTS (
      SELECT 1
      FROM information_schema.routine_privileges
      WHERE specific_schema = 'public'
        AND routine_name = v_rpc
        AND grantee IN ('anon', 'PUBLIC')
        AND privilege_type = 'EXECUTE'
    ) THEN
      RAISE EXCEPTION 'FAIL: client RPC % unexpectedly executable by anon/PUBLIC', v_rpc;
    END IF;
  END LOOP;

  RAISE NOTICE '[FriendGroups] sql_objects_and_grants_ok';
END $$;

-- Privilege matrix helper (run after 20260959):
-- SELECT routine_name, grantee, privilege_type
-- FROM information_schema.routine_privileges
-- WHERE specific_schema = 'public'
--   AND routine_name LIKE 'friend_group%'
--    OR routine_name LIKE '%friend_group%'
-- ORDER BY routine_name, grantee;

-- Behavioral matrix (staging fixtures; replace UUIDs):
-- F) create_friend_group('Soccer Friends') as owner → succeeds
-- G) set_friend_group_members(group_id, '{friend_uuid}') → succeeds for accepted friend
-- H) accepted-friend validation still runs inside set_friend_group_members
-- I) set_friend_group_members with non-friend UUID → rejected
-- J) other user cannot list/rename/delete/set members on owner''s group
-- K) DELETE accepted friendship → friend_group_members rows cleaned for both owners
;
