-- =============================================================================
-- 20260959_0001 — Friend Groups helper EXECUTE hardening (post-20260955)
-- =============================================================================
-- 20260955 is already applied. This corrective migration does NOT change
-- Friend Groups tables, RLS, RPC bodies, or user-facing behavior.
--
-- CODE-PROVEN ISSUE:
--   friend_groups_users_are_accepted_friends(uuid, uuid) was GRANT EXECUTE to
--   authenticated. Any signed-in client could probe arbitrary UUID pairs and
--   learn accepted-friend status (social-graph disclosure).
--
--   friend_groups_normalize_name(text) was also GRANT EXECUTE to authenticated
--   though iOS never calls it (normalization happens inside create/rename RPCs).
--
-- FIX:
--   REVOKE direct EXECUTE on both internal helpers from PUBLIC / anon /
--   authenticated. Keep service_role for backend/ops only.
--
-- SECURITY DEFINER RPCs that call these helpers continue to work: they run as
-- the function owner and do not require the end-user role to EXECUTE the helper.
--
-- Client-facing RPCs (list/create/rename/delete/members/set/…) are unchanged.
--
-- Do NOT apply from the agent. Apply manually after 20260955 (and after any
-- already-applied later migrations in the same environment).
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Social-graph probe helper — internal only
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.friend_groups_users_are_accepted_friends(uuid, uuid)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.friend_groups_users_are_accepted_friends(uuid, uuid)
  FROM anon;
REVOKE ALL ON FUNCTION public.friend_groups_users_are_accepted_friends(uuid, uuid)
  FROM authenticated;

GRANT EXECUTE ON FUNCTION public.friend_groups_users_are_accepted_friends(uuid, uuid)
  TO service_role;

COMMENT ON FUNCTION public.friend_groups_users_are_accepted_friends(uuid, uuid) IS
  'INTERNAL Friend Groups helper: accepted-friend check for SECURITY DEFINER RPCs. '
  'Not a client RPC — EXECUTE revoked from authenticated/anon/PUBLIC (20260959).';

-- ---------------------------------------------------------------------------
-- 2) Name normalization helper — internal only
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.friend_groups_normalize_name(text)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.friend_groups_normalize_name(text)
  FROM anon;
REVOKE ALL ON FUNCTION public.friend_groups_normalize_name(text)
  FROM authenticated;

GRANT EXECUTE ON FUNCTION public.friend_groups_normalize_name(text)
  TO service_role;

COMMENT ON FUNCTION public.friend_groups_normalize_name(text) IS
  'INTERNAL Friend Groups helper: trims/validates group name for create/rename RPCs. '
  'Not a client RPC — EXECUTE revoked from authenticated/anon/PUBLIC (20260959).';

-- Trigger function friend_groups_cleanup_on_friendship_delete is not a client RPC
-- (invoked only by trg_friend_groups_cleanup_on_friendship_delete). No client grants
-- were issued in 20260955; leave trigger privileges unchanged.

COMMIT;

-- MANUAL APPLY NOTES
-- 1) Apply in Supabase SQL editor / migration runner AFTER relying on hardened grants.
-- 2) Run supabase/tests/friend_groups_checks.sql in staging afterward.
-- 3) No Edge deploy. No iOS change.
;
