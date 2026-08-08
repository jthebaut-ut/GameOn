-- =============================================================================
-- 20260915_0002 — Friendships RLS (repo-versioned) + accept block check
-- =============================================================================
-- Versions Dashboard-only friendships RLS into a reviewable migration.
-- Mutations remain SECURITY DEFINER RPC-only.
--
-- Strategy:
--   1) ENABLE + FORCE RLS
--   2) Drop EVERY existing policy on friendships (unknown Dashboard names included)
--   3) Recreate only SELECT involving me
--   4) Revoke table INSERT/UPDATE/DELETE from clients
--
-- iOS mutations already use DEFINER RPCs:
--   friendship_ensure_pending, friendship_ensure_pending_to_business,
--   accept_friend_request, decline_friend_request, cancel_outgoing_friend_request,
--   clear_friend_request_view, remove_friend
--
-- FORCE RLS: client roles cannot bypass. Supabase SECURITY DEFINER functions
-- owned by a superuser/bypass role continue to mutate as today.
--
-- Do NOT apply from the agent; review and apply deliberately.
-- =============================================================================

BEGIN;

ALTER TABLE public.friendships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.friendships FORCE ROW LEVEL SECURITY;

-- Drop every policy (SELECT/INSERT/UPDATE/DELETE) so unknown Dashboard
-- write policies cannot survive. Then recreate the single intended SELECT.
DO $$
DECLARE
  pol record;
BEGIN
  FOR pol IN
    SELECT policyname
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'friendships'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.friendships', pol.policyname);
  END LOOP;
END $$;

CREATE POLICY "friendships_select_involving_me"
ON public.friendships
FOR SELECT
TO authenticated
USING (
  requester_id = auth.uid()
  OR addressee_id = auth.uid()
);

-- Intentionally NO INSERT / UPDATE / DELETE policies for authenticated.

REVOKE INSERT, UPDATE, DELETE ON TABLE public.friendships FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.friendships FROM anon;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.friendships FROM PUBLIC;
REVOKE ALL ON TABLE public.friendships FROM anon;
REVOKE ALL ON TABLE public.friendships FROM PUBLIC;

GRANT SELECT ON TABLE public.friendships TO authenticated;
GRANT ALL ON TABLE public.friendships TO service_role;

COMMENT ON TABLE public.friendships IS
  'User/business friendship edges. RLS FORCE: SELECT involving me only; mutations via DEFINER RPCs. Dashboard policies superseded by 20260915_0002.';

-- ---------------------------------------------------------------------------
-- accept_friend_request: also reject when a block exists either direction
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.accept_friend_request(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_requester uuid;
  n int;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  IF p_id IS NULL THEN
    RAISE EXCEPTION 'Friend request not found or cannot be accepted.';
  END IF;

  -- Idempotent: already accepted for this addressee (double-tap / realtime race).
  IF EXISTS (
    SELECT 1
    FROM public.friendships f
    WHERE f.id = p_id
      AND f.addressee_id = me
      AND lower(btrim(coalesce(f.status, ''))) = 'accepted'
  ) THEN
    RETURN;
  END IF;

  SELECT f.requester_id
    INTO v_requester
  FROM public.friendships f
  WHERE f.id = p_id
    AND f.addressee_id = me
    AND lower(btrim(coalesce(f.status, ''))) = 'pending'
  LIMIT 1;

  IF v_requester IS NULL THEN
    RAISE EXCEPTION 'Friend request not found or cannot be accepted.';
  END IF;

  -- Mirror friendship_ensure_pending: either-direction block blocks accept.
  IF EXISTS (
    SELECT 1
    FROM public.blocked_users b
    WHERE (b.blocker_user_id = me AND b.blocked_user_id = v_requester)
       OR (b.blocker_user_id = v_requester AND b.blocked_user_id = me)
  ) THEN
    RAISE EXCEPTION 'You can''t accept a friend request from this user.';
  END IF;

  UPDATE public.friendships f
  SET
    status = 'accepted',
    responded_at = now()
  WHERE f.id = p_id
    AND f.addressee_id = me
    AND lower(btrim(coalesce(f.status, ''))) = 'pending';

  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN
    RAISE EXCEPTION 'Friend request not found or cannot be accepted.';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.accept_friend_request(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.accept_friend_request(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.accept_friend_request(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.accept_friend_request(uuid) TO service_role;

COMMENT ON FUNCTION public.accept_friend_request(uuid) IS
  'Addressee accepts a pending user friendship. Rejects if either party has a blocked_users row (mirrors friendship_ensure_pending). Idempotent if already accepted.';

NOTIFY pgrst, 'reload schema';

COMMIT;
