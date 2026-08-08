-- =============================================================================
-- 20260915_0003 — Direct-messages immutable-column ALLOWLIST + report RPC
-- =============================================================================
-- Authenticated/anon UPDATE may change ONLY:
--   report_count, is_deleted, deleted_at
-- Every other column must equal OLD (present and future columns).
--
-- Preferred moderation path: bump_direct_message_report_count(uuid) SECURITY DEFINER
-- (no client UPDATE required). UPDATE policy is dropped / UPDATE revoked so clients
-- cannot mutate rows directly; DEFINER RPCs and service_role remain writers.
--
-- No client-activatable GUC bypass.
--
-- Do NOT apply from the agent; review and apply deliberately.
-- Apply AFTER shipping iOS that calls bump_direct_message_report_count (or same
-- release train). Ordering with 0005: either before or after is fine.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Allowlist-only BEFORE UPDATE trigger
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enforce_direct_messages_immutable_columns()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text := coalesce(auth.role(), '');
BEGIN
  -- Non-client roles (service_role, postgres, etc.) may update freely.
  IF v_role NOT IN ('authenticated', 'anon') THEN
    RETURN NEW;
  END IF;

  -- Explicit allowlist: only report_count / is_deleted / deleted_at may differ.
  -- Strip those three keys from both row JSON and require the remainders match,
  -- so any present or future column outside the allowlist is frozen.
  IF (to_jsonb(NEW) - 'report_count' - 'is_deleted' - 'deleted_at')
       IS NOT DISTINCT FROM
     (to_jsonb(OLD) - 'report_count' - 'is_deleted' - 'deleted_at')
  THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'not allowed to update protected direct_messages columns'
    USING ERRCODE = '42501';
END;
$$;

COMMENT ON FUNCTION public.enforce_direct_messages_immutable_columns() IS
  'BEFORE UPDATE allowlist for authenticated/anon: only report_count, is_deleted, deleted_at may change. All other columns (including future columns) must match OLD. No client GUC bypass.';

REVOKE ALL ON FUNCTION public.enforce_direct_messages_immutable_columns() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.enforce_direct_messages_immutable_columns() FROM anon;
REVOKE ALL ON FUNCTION public.enforce_direct_messages_immutable_columns() FROM authenticated;

DROP TRIGGER IF EXISTS trg_direct_messages_immutable_columns ON public.direct_messages;
CREATE TRIGGER trg_direct_messages_immutable_columns
  BEFORE UPDATE ON public.direct_messages
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_direct_messages_immutable_columns();

-- ---------------------------------------------------------------------------
-- 2) Trusted report-count bump (replaces client PostgREST UPDATE)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bump_direct_message_report_count(p_message_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_msg public.direct_messages%ROWTYPE;
  v_next int;
  v_hide_threshold int := 3;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.' USING ERRCODE = '42501';
  END IF;

  IF p_message_id IS NULL THEN
    RAISE EXCEPTION 'Message required.' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_msg
  FROM public.direct_messages
  WHERE id = p_message_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Message not found.' USING ERRCODE = 'P0002';
  END IF;

  IF NOT public.is_direct_conversation_participant(v_msg.conversation_id, me) THEN
    RAISE EXCEPTION 'Not authorized.' USING ERRCODE = '42501';
  END IF;

  -- Reporter must not bump their own outbound message via this path for spam;
  -- moderation reports are separate. Allow any participant (matches prior client path).
  v_next := coalesce(v_msg.report_count, 0) + 1;

  IF v_next >= v_hide_threshold THEN
    UPDATE public.direct_messages
    SET report_count = v_next,
        is_deleted = true,
        deleted_at = coalesce(deleted_at, now())
    WHERE id = p_message_id;
  ELSE
    UPDATE public.direct_messages
    SET report_count = v_next
    WHERE id = p_message_id;
  END IF;

  RETURN v_next;
END;
$$;

COMMENT ON FUNCTION public.bump_direct_message_report_count(uuid) IS
  'SECURITY DEFINER: participant increments report_count; at threshold 3 sets is_deleted. Prefer over direct table UPDATE.';

REVOKE ALL ON FUNCTION public.bump_direct_message_report_count(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.bump_direct_message_report_count(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.bump_direct_message_report_count(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.bump_direct_message_report_count(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3) Deny authenticated direct UPDATE (RPC-only mutations)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  pol record;
BEGIN
  FOR pol IN
    SELECT policyname
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'direct_messages'
      AND cmd = 'UPDATE'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.direct_messages', pol.policyname);
  END LOOP;
END $$;

REVOKE UPDATE ON TABLE public.direct_messages FROM authenticated;
REVOKE UPDATE ON TABLE public.direct_messages FROM anon;
REVOKE UPDATE ON TABLE public.direct_messages FROM PUBLIC;

NOTIFY pgrst, 'reload schema';

COMMIT;
