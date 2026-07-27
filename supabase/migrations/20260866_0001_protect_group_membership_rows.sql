-- =============================================================================
-- 20260866 — Protect group_conversation_members from client self-promotion
-- =============================================================================
--
-- Production verified:
--   Policy group_members_update_own_active allows any active member to UPDATE
--   their own row with WITH CHECK (user_id = auth.uid()) only — so role,
--   left_at, joined_at, conversation_id, etc. are client-mutable.
--   Table grants also give anon/authenticated broad INSERT/UPDATE/DELETE.
--
-- Writer inventory (audit; comments only):
--   iOS GroupChatService:
--     SELECT only on group_conversation_members (inbox avatar clusters)
--     mark read  → RPC mark_group_conversation_read
--     mute       → RPC set_group_conversation_muted
--     leave      → RPC leave_group_conversation
--     create/add/remove → create_group_conversation / add_group_members /
--                         remove_group_member
--     send       → RPC send_group_message (also bumps last_read_at server-side)
--     NO direct PostgREST UPDATE/INSERT/DELETE on membership rows
--
--   Trusted SECURITY DEFINER writers (must keep working):
--     create_group_conversation, add_group_members, remove_group_member,
--     leave_group_conversation, mark_group_conversation_read,
--     set_group_conversation_muted, send_group_message
--
-- Enforcement:
--   1) Drop dangerous UPDATE policy
--   2) Revoke client write grants; keep SELECT for authenticated (RLS peers)
--   3) Defense-in-depth BEFORE UPDATE trigger: when current_user is a client
--      role (authenticated/anon), only last_read_at / muted_until may change.
--      SECURITY DEFINER RPCs run as function owner, so current_user elevates
--      and trusted membership mutations continue to work without GUCs.
--
-- Preserve SELECT policy group_members_select_active_peers (unchanged).
-- Do NOT apply full unrelated admin migrations here.
-- Do NOT apply from the agent; review and apply deliberately.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- PREFLIGHT
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
  v_col text;
  v_required_cols text[] := ARRAY[
    'conversation_id',
    'user_id',
    'role',
    'joined_at',
    'left_at',
    'muted_until',
    'last_read_at'
  ];
  v_fn text;
  v_required_fns text[] := ARRAY[
    'public.mark_group_conversation_read(uuid)',
    'public.set_group_conversation_muted(uuid,boolean)',
    'public.leave_group_conversation(uuid)',
    'public.create_group_conversation(text,uuid[])',
    'public.add_group_members(uuid,uuid[])',
    'public.remove_group_member(uuid,uuid)',
    'public.send_group_message(uuid,text)',
    'public.is_active_group_member(uuid,uuid)'
  ];
BEGIN
  IF to_regclass('public.group_conversation_members') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.group_conversation_members'];
  END IF;

  IF to_regclass('public.group_conversation_members') IS NOT NULL THEN
    FOREACH v_col IN ARRAY v_required_cols
    LOOP
      IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns c
        WHERE c.table_schema = 'public'
          AND c.table_name = 'group_conversation_members'
          AND c.column_name = v_col
      ) THEN
        v_missing := v_missing || ARRAY['column public.group_conversation_members.' || v_col];
      END IF;
    END LOOP;
  END IF;

  FOREACH v_fn IN ARRAY v_required_fns
  LOOP
    IF to_regprocedure(v_fn) IS NULL THEN
      v_missing := v_missing || ARRAY['function ' || v_fn];
    END IF;
  END LOOP;

  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION
      '20260866 preflight failed — missing required dependencies (no schema changes applied): %',
      array_to_string(v_missing, ', ')
      USING ERRCODE = 'P0001';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 1) Drop dangerous generic UPDATE policy
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS "group_members_update_own_active"
  ON public.group_conversation_members;

-- Preserve peer SELECT (reaffirm; do not weaken).
DROP POLICY IF EXISTS "group_members_select_active_peers"
  ON public.group_conversation_members;
CREATE POLICY "group_members_select_active_peers"
ON public.group_conversation_members
FOR SELECT
TO authenticated
USING (public.is_active_group_member(conversation_id, auth.uid()));

COMMENT ON POLICY "group_members_select_active_peers" ON public.group_conversation_members IS
  'Active members may SELECT peer membership rows in their own groups only. Nonmembers cannot enumerate.';

-- ---------------------------------------------------------------------------
-- 2) Defense-in-depth: freeze membership-control columns for client roles
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.enforce_group_membership_privileged_columns()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_changed text[] := ARRAY[]::text[];
BEGIN
  -- Client sessions (PostgREST as authenticated/anon) may only touch personal
  -- mute/read fields. Trusted SECURITY DEFINER RPCs elevate current_user to the
  -- function owner and bypass this branch.
  IF current_user::text IN ('authenticated', 'anon') THEN
    IF NEW.role IS DISTINCT FROM OLD.role THEN
      v_changed := v_changed || ARRAY['role'];
    END IF;
    IF NEW.user_id IS DISTINCT FROM OLD.user_id THEN
      v_changed := v_changed || ARRAY['user_id'];
    END IF;
    IF NEW.conversation_id IS DISTINCT FROM OLD.conversation_id THEN
      v_changed := v_changed || ARRAY['conversation_id'];
    END IF;
    IF NEW.joined_at IS DISTINCT FROM OLD.joined_at THEN
      v_changed := v_changed || ARRAY['joined_at'];
    END IF;
    IF NEW.left_at IS DISTINCT FROM OLD.left_at THEN
      v_changed := v_changed || ARRAY['left_at'];
    END IF;

    IF cardinality(v_changed) > 0 THEN
      RAISE EXCEPTION
        'not allowed to update privileged group membership columns: %',
        array_to_string(v_changed, ', ')
        USING ERRCODE = '42501';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.enforce_group_membership_privileged_columns() IS
  'BEFORE UPDATE guard: client roles authenticated/anon cannot change role/user_id/conversation_id/joined_at/left_at. last_read_at and muted_until remain allowed for defense-in-depth; preferred path is mark/mute RPCs. SECURITY DEFINER membership RPCs elevate current_user and may mutate control fields.';

REVOKE ALL ON FUNCTION public.enforce_group_membership_privileged_columns() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.enforce_group_membership_privileged_columns() FROM anon;
REVOKE ALL ON FUNCTION public.enforce_group_membership_privileged_columns() FROM authenticated;

DROP TRIGGER IF EXISTS trg_group_membership_privileged_columns
  ON public.group_conversation_members;
CREATE TRIGGER trg_group_membership_privileged_columns
  BEFORE UPDATE ON public.group_conversation_members
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_group_membership_privileged_columns();

-- ---------------------------------------------------------------------------
-- 3) Reaffirm narrow personal-state RPCs (bodies unchanged; grants tightened)
-- ---------------------------------------------------------------------------

-- mark_group_conversation_read / set_group_conversation_muted already exist and
-- are the iOS paths. Re-apply EXECUTE grants only (no body rewrite).

REVOKE ALL ON FUNCTION public.mark_group_conversation_read(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mark_group_conversation_read(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.mark_group_conversation_read(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_group_conversation_read(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.set_group_conversation_muted(uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_group_conversation_muted(uuid, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_group_conversation_muted(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_group_conversation_muted(uuid, boolean) TO service_role;

-- Harden EXECUTE on other membership-mutating RPCs (anon must not call).
REVOKE ALL ON FUNCTION public.create_group_conversation(text, uuid[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_group_conversation(text, uuid[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.create_group_conversation(text, uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_group_conversation(text, uuid[]) TO service_role;

REVOKE ALL ON FUNCTION public.add_group_members(uuid, uuid[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.add_group_members(uuid, uuid[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.add_group_members(uuid, uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.add_group_members(uuid, uuid[]) TO service_role;

REVOKE ALL ON FUNCTION public.remove_group_member(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.remove_group_member(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.remove_group_member(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_group_member(uuid, uuid) TO service_role;

REVOKE ALL ON FUNCTION public.leave_group_conversation(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.leave_group_conversation(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.leave_group_conversation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.leave_group_conversation(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.send_group_message(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.send_group_message(uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.send_group_message(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.send_group_message(uuid, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 4) Table grants — no client writes; SELECT retained for RLS peer reads
-- ---------------------------------------------------------------------------

REVOKE ALL ON TABLE public.group_conversation_members FROM PUBLIC;
REVOKE ALL ON TABLE public.group_conversation_members FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.group_conversation_members FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.group_conversation_members FROM authenticated;

GRANT SELECT ON TABLE public.group_conversation_members TO authenticated;
GRANT ALL ON TABLE public.group_conversation_members TO service_role;

COMMENT ON TABLE public.group_conversation_members IS
  'Membership source of truth for group chats. Soft-leave via left_at. Client writes forbidden; mutate via SECURITY DEFINER RPCs only. Authenticated SELECT allowed under group_members_select_active_peers.';

COMMENT ON COLUMN public.group_conversation_members.role IS
  'admin|member. Client UPDATE forbidden; change only via trusted group-management RPCs.';
COMMENT ON COLUMN public.group_conversation_members.left_at IS
  'Soft-leave timestamp. Client UPDATE forbidden; set via leave/remove RPCs.';
COMMENT ON COLUMN public.group_conversation_members.joined_at IS
  'Membership join time. Client UPDATE forbidden.';
COMMENT ON COLUMN public.group_conversation_members.last_read_at IS
  'Read cursor. Prefer mark_group_conversation_read / send_group_message RPCs.';
COMMENT ON COLUMN public.group_conversation_members.muted_until IS
  'Mute expiry. Prefer set_group_conversation_muted RPC.';

COMMIT;

-- =============================================================================
-- POST-APPLY READ-ONLY VALIDATION (manual; SELECT only — no production writes)
-- =============================================================================
--
-- -- Policies
-- SELECT policyname, cmd, roles, qual, with_check
-- FROM pg_policies
-- WHERE schemaname = 'public'
--   AND tablename = 'group_conversation_members'
-- ORDER BY policyname;
-- -- Expect: group_members_select_active_peers only (no group_members_update_own_active)
--
-- -- Trigger
-- SELECT tgname, pg_get_triggerdef(oid)
-- FROM pg_trigger
-- WHERE tgrelid = 'public.group_conversation_members'::regclass
--   AND NOT tgisinternal
--   AND tgname = 'trg_group_membership_privileged_columns';
--
-- -- Table grants
-- SELECT grantee, privilege_type
-- FROM information_schema.role_table_grants
-- WHERE table_schema = 'public'
--   AND table_name = 'group_conversation_members'
-- ORDER BY grantee, privilege_type;
--
-- SELECT COUNT(*) AS anon_write_grants
-- FROM information_schema.role_table_grants
-- WHERE table_schema = 'public'
--   AND table_name = 'group_conversation_members'
--   AND grantee = 'anon'
--   AND privilege_type IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER');
-- -- expect 0
--
-- SELECT COUNT(*) AS authenticated_write_grants
-- FROM information_schema.role_table_grants
-- WHERE table_schema = 'public'
--   AND table_name = 'group_conversation_members'
--   AND grantee = 'authenticated'
--   AND privilege_type IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE');
-- -- expect 0
--
-- SELECT COUNT(*) AS authenticated_select_grants
-- FROM information_schema.role_table_grants
-- WHERE table_schema = 'public'
--   AND table_name = 'group_conversation_members'
--   AND grantee = 'authenticated'
--   AND privilege_type = 'SELECT';
-- -- expect >= 1
--
-- -- RPC grants (no anon EXECUTE)
-- SELECT r.routine_name, p.grantee, p.privilege_type
-- FROM information_schema.routine_privileges p
-- JOIN information_schema.routines r
--   ON r.specific_name = p.specific_name
--  AND r.specific_schema = p.specific_schema
-- WHERE p.specific_schema = 'public'
--   AND r.routine_name IN (
--     'mark_group_conversation_read',
--     'set_group_conversation_muted',
--     'leave_group_conversation',
--     'create_group_conversation',
--     'add_group_members',
--     'remove_group_member',
--     'send_group_message'
--   )
-- ORDER BY r.routine_name, p.grantee;
--
-- =============================================================================
-- Staging test matrix (staging only):
-- 1) Member direct UPDATE role='admin' → fail (no privilege / no policy / trigger)
-- 2) Member direct UPDATE left_at → fail
-- 3) Member direct UPDATE joined_at → fail
-- 4) Member direct UPDATE conversation_id → fail
-- 5) Member direct UPDATE user_id → fail
-- 6) mark_group_conversation_read → OK
-- 7) set_group_conversation_muted → OK
-- 8) leave_group_conversation → OK (incl. last-admin promotion)
-- 9) Last-admin leave promotes replacement → OK
-- 10) remove_group_member → OK
-- 11) add_group_members → OK
-- 12) create_group_conversation → OK
-- 13) Active member SELECT peers → OK
-- 14) Nonmember SELECT memberships → empty / denied
-- 15) anon write privileges → none
-- 16) Released iOS group chat (inbox/read/mute/leave/send) → OK
--
-- Rollback (manual; prefer forward-fix):
--   BEGIN;
--   DROP TRIGGER IF EXISTS trg_group_membership_privileged_columns
--     ON public.group_conversation_members;
--   DROP FUNCTION IF EXISTS public.enforce_group_membership_privileged_columns();
--   -- Recreate prior UPDATE policy only if intentionally reverting security:
--   -- CREATE POLICY group_members_update_own_active ...
--   -- Re-grant table writes only if historically required (not recommended).
--   COMMIT;
-- =============================================================================
