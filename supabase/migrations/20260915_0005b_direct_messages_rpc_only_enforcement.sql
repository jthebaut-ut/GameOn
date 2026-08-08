-- =============================================================================
-- 20260915_0005b — Enforce RPC-only direct_messages INSERT
-- =============================================================================
-- PHASE B — apply ONLY after:
--   1) 20260915_0005a has been applied (send_direct_message exists)
--   2) RPC-only iOS build is released to users
--   3) Old PostgREST-INSERT clients are intentionally ended
--
-- Drops authenticated INSERT policies and revokes INSERT on direct_messages.
-- Preserves service_role. Does not weaken send_direct_message security.
--
-- Do NOT apply from the agent; review and apply deliberately.
-- =============================================================================

BEGIN;

DO $$
DECLARE
  v_proc regprocedure := COALESCE(
    to_regprocedure('public.send_direct_message(uuid, text, uuid)'),
    to_regprocedure('public.send_direct_message(uuid, text)')
  );
BEGIN
  -- Accept 0005a two-arg form or later reply-capable three-arg form (DEFAULT NULL).
  IF v_proc IS NULL THEN
    RAISE EXCEPTION
      '20260915_0005b prerequisite missing: public.send_direct_message(uuid, text[, uuid]). Apply 20260915_0005a (and optionally 20260917_0001 replies) first.'
      USING ERRCODE = 'P0001';
  END IF;

  IF NOT has_function_privilege('authenticated', v_proc, 'EXECUTE') THEN
    RAISE EXCEPTION
      '20260915_0005b prerequisite failed: authenticated lacks EXECUTE on send_direct_message'
      USING ERRCODE = 'P0001';
  END IF;
END $$;

-- Drop every INSERT policy on direct_messages (unknown Dashboard names included).
DO $$
DECLARE
  pol record;
BEGIN
  FOR pol IN
    SELECT policyname
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'direct_messages'
      AND cmd = 'INSERT'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.direct_messages', pol.policyname);
  END LOOP;
END $$;

REVOKE INSERT ON TABLE public.direct_messages FROM authenticated;
REVOKE INSERT ON TABLE public.direct_messages FROM anon;
REVOKE INSERT ON TABLE public.direct_messages FROM PUBLIC;

-- service_role retains ALL (or at least INSERT) for DEFINER / ops paths.
GRANT ALL ON TABLE public.direct_messages TO service_role;

DO $$
BEGIN
  IF to_regprocedure('public.send_direct_message(uuid, text, uuid)') IS NOT NULL THEN
    EXECUTE $c$
      COMMENT ON FUNCTION public.send_direct_message(uuid, text, uuid) IS
        'Sole authenticated DM send path after Phase B (reply-capable): rate-limited (60/60s), sender=auth.uid(), gated by direct_message_send_allowed. Direct table INSERT revoked for authenticated.'
    $c$;
  ELSIF to_regprocedure('public.send_direct_message(uuid, text)') IS NOT NULL THEN
    EXECUTE $c$
      COMMENT ON FUNCTION public.send_direct_message(uuid, text) IS
        'Sole authenticated DM send path after Phase B: rate-limited (60/60s), sender=auth.uid(), gated by direct_message_send_allowed. Direct table INSERT revoked for authenticated.'
    $c$;
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
