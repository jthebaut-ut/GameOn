-- Unfriend: remove accepted user↔user friendship edge (DM history preserved).
-- iOS calls public.remove_friend(p_friend_user_id) from FriendshipService.removeFriend.

CREATE OR REPLACE FUNCTION public.remove_friend(p_friend_user_id uuid)
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

  IF p_friend_user_id IS NULL OR p_friend_user_id = me THEN
    RAISE EXCEPTION 'Invalid friend user.';
  END IF;

  DELETE FROM public.friendships f
  WHERE f.status = 'accepted'
    AND coalesce(f.requester_entity_type, 'user') = 'user'
    AND coalesce(f.addressee_entity_type, 'user') = 'user'
    AND (
      (f.requester_id = me AND f.addressee_id = p_friend_user_id)
      OR (f.requester_id = p_friend_user_id AND f.addressee_id = me)
    );

  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN
    RAISE EXCEPTION 'Friendship not found or cannot be removed.';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.remove_friend(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.remove_friend(uuid) TO authenticated;

COMMENT ON FUNCTION public.remove_friend(uuid) IS
  'Authenticated user deletes an accepted user-to-user friendship with p_friend_user_id. Pending requests and business friendships are untouched; DMs are not cleared.';
