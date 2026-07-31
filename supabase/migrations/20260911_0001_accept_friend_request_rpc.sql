-- Accept friend request via SECURITY DEFINER RPC (mirrors decline_friend_request).
-- Client-side UPDATE ... SELECT ... single() fails with PGRST116
-- "Cannot coerce the result to a single JSON object" when PostgREST representation
-- returns zero rows under RLS, even though the UPDATE already succeeded.

CREATE OR REPLACE FUNCTION public.accept_friend_request(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
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
GRANT EXECUTE ON FUNCTION public.accept_friend_request(uuid) TO authenticated;

COMMENT ON FUNCTION public.accept_friend_request(uuid) IS
  'Addressee accepts a pending user friendship. Idempotent if already accepted. Avoids PostgREST UPDATE+single() RLS representation failures.';
