-- FanGeo Support Center: user-initiated ticket cancellation.
-- Does not touch direct_messages, direct_conversations, friendships, or admin dashboard RPCs.

ALTER TABLE public.support_conversations
  ADD COLUMN IF NOT EXISTS closed_at timestamptz,
  ADD COLUMN IF NOT EXISTS closed_by text;

ALTER TABLE public.support_conversations
  DROP CONSTRAINT IF EXISTS support_conversations_status_check;

ALTER TABLE public.support_conversations
  ADD CONSTRAINT support_conversations_status_check
  CHECK (status IN ('open', 'closed', 'cancelled'));

CREATE OR REPLACE FUNCTION public.cancel_my_support_ticket(
  p_conversation_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_updated integer;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  IF p_conversation_id IS NULL THEN
    RAISE EXCEPTION 'invalid conversation';
  END IF;

  UPDATE public.support_conversations sc
  SET
    status = 'cancelled',
    closed_at = now(),
    closed_by = 'user',
    updated_at = now()
  WHERE sc.id = p_conversation_id
    AND sc.user_id = v_uid
    AND sc.status = 'open';

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated = 0 THEN
    RAISE EXCEPTION 'ticket not found or cannot be cancelled';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_my_support_ticket(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancel_my_support_ticket(uuid) TO authenticated;

COMMENT ON FUNCTION public.cancel_my_support_ticket(uuid) IS
  'Allows the authenticated user to cancel their own open support ticket.';
