-- =============================================================================
-- 20260915_0005a — Messaging rate limits + send_direct_message (COMPAT)
-- =============================================================================
-- PHASE A — safe for dual-client rollout:
--   • Creates rpc_rate_limits + assert_rpc_rate_limit
--   • Creates/wires send_direct_message (rate-limited, auth.uid() sender)
--   • Rate-limits send_group_message / friendship_ensure_pending / poke /
--     report_group_message
--   • PRESERVES existing authenticated INSERT policy + INSERT grant on
--     public.direct_messages so old production builds keep working
--
-- New iOS (RPC-only) → call send_direct_message
-- Old iOS (PostgREST INSERT) → still works until Phase B (0005b)
--
-- Exact RPC signature (must match Swift named params):
--   public.send_direct_message(p_conversation_id uuid, p_body text) RETURNS uuid
--
-- Do NOT apply from the agent; review and apply deliberately.
-- Do NOT apply 0005b until RPC-only iOS is released and old INSERT clients
-- are intentionally ended.
-- =============================================================================

BEGIN;

-- Drop any accidental alternate overloads that would confuse PostgREST.
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'send_direct_message'
      AND pg_get_function_identity_arguments(p.oid)
            IS DISTINCT FROM 'p_conversation_id uuid, p_body text'
  LOOP
    EXECUTE 'DROP FUNCTION IF EXISTS ' || r.sig;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 1) Rate-limit table + assert helper
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.rpc_rate_limits (
  actor_uid uuid NOT NULL,
  bucket text NOT NULL,
  window_start timestamptz NOT NULL,
  count int NOT NULL DEFAULT 0,
  CONSTRAINT rpc_rate_limits_actor_bucket_window_uidx
    UNIQUE (actor_uid, bucket, window_start),
  CONSTRAINT rpc_rate_limits_count_nonneg CHECK (count >= 0),
  CONSTRAINT rpc_rate_limits_bucket_nonempty CHECK (length(btrim(bucket)) > 0)
);

ALTER TABLE public.rpc_rate_limits DROP CONSTRAINT IF EXISTS rpc_rate_limits_count_bounded;
ALTER TABLE public.rpc_rate_limits
  ADD CONSTRAINT rpc_rate_limits_count_bounded CHECK (count <= 1000000);

COMMENT ON TABLE public.rpc_rate_limits IS
  'Per-actor fixed-window counters for SECURITY DEFINER RPC rate limiting. Client has no direct access.';

ALTER TABLE public.rpc_rate_limits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rpc_rate_limits FORCE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.rpc_rate_limits FROM PUBLIC;
REVOKE ALL ON TABLE public.rpc_rate_limits FROM anon;
REVOKE ALL ON TABLE public.rpc_rate_limits FROM authenticated;
GRANT ALL ON TABLE public.rpc_rate_limits TO service_role;

CREATE OR REPLACE FUNCTION public.assert_rpc_rate_limit(
  p_bucket text,
  p_max int,
  p_window_seconds int
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_bucket text := nullif(btrim(coalesce(p_bucket, '')), '');
  v_window_start timestamptz;
  v_count int;
  v_allowed_buckets text[] := ARRAY[
    'send_direct_message',
    'send_group_message',
    'friendship_ensure_pending',
    'poke_profile',
    'report_group_message'
  ];
BEGIN
  IF coalesce(auth.role(), '') = 'service_role' AND me IS NULL THEN
    RETURN;
  END IF;

  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  IF v_bucket IS NULL OR NOT (v_bucket = ANY (v_allowed_buckets)) THEN
    RAISE EXCEPTION 'rate limit rejected' USING ERRCODE = '22023';
  END IF;

  IF p_max IS NULL OR p_max < 1 OR p_max > 100000 THEN
    RAISE EXCEPTION 'rate limit rejected' USING ERRCODE = '22023';
  END IF;

  IF p_window_seconds IS NULL OR p_window_seconds < 1 OR p_window_seconds > 86400 THEN
    RAISE EXCEPTION 'rate limit rejected' USING ERRCODE = '22023';
  END IF;

  v_window_start := to_timestamp(
    floor(extract(epoch FROM now()) / p_window_seconds::double precision)
      * p_window_seconds::double precision
  );

  INSERT INTO public.rpc_rate_limits AS r (actor_uid, bucket, window_start, count)
  VALUES (me, v_bucket, v_window_start, 1)
  ON CONFLICT (actor_uid, bucket, window_start)
  DO UPDATE SET count = LEAST(r.count + 1, 1000000)
  RETURNING r.count INTO v_count;

  IF v_count > p_max THEN
    RAISE EXCEPTION 'rate_limit_exceeded'
      USING ERRCODE = '54000';
  END IF;

  IF (random() < 0.01) THEN
    DELETE FROM public.rpc_rate_limits
    WHERE window_start < (now() - interval '7 days');
  END IF;
END;
$$;

COMMENT ON FUNCTION public.assert_rpc_rate_limit(text, int, int) IS
  'SECURITY DEFINER fixed-window rate limit with allowlisted buckets. Raises generic 54000 rate_limit_exceeded. Invoked by peer DEFINER RPCs; not granted to authenticated clients.';

REVOKE ALL ON FUNCTION public.assert_rpc_rate_limit(text, int, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.assert_rpc_rate_limit(text, int, int) FROM anon;
REVOKE ALL ON FUNCTION public.assert_rpc_rate_limit(text, int, int) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.assert_rpc_rate_limit(text, int, int) TO service_role;

-- ---------------------------------------------------------------------------
-- 2) send_group_message — rate limit + latest pickup-auth body (20260893)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.send_group_message(
  p_conversation_id uuid,
  p_body text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_body text := btrim(coalesce(p_body, ''));
  v_id uuid;
  v_preview text;
  v_pickup_game_id uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  PERFORM public.assert_rpc_rate_limit('send_group_message', 60, 60);

  IF char_length(v_body) < 1 THEN
    RAISE EXCEPTION 'Message body required.';
  END IF;

  IF NOT public.is_active_group_member(p_conversation_id, me) THEN
    RAISE EXCEPTION 'Not an active member.';
  END IF;

  SELECT c.pickup_game_id INTO v_pickup_game_id
  FROM public.group_conversations c
  WHERE c.id = p_conversation_id;

  IF v_pickup_game_id IS NOT NULL
     AND NOT public.is_pickup_game_chat_authorized(v_pickup_game_id, me) THEN
    RAISE EXCEPTION 'Not authorized for this pickup game chat.'
      USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.group_messages (conversation_id, sender_id, body, message_type)
  VALUES (p_conversation_id, me, v_body, 'text')
  RETURNING id INTO v_id;

  v_preview := left(v_body, 180);

  UPDATE public.group_conversations
  SET
    last_message_at = now(),
    last_message_preview = v_preview,
    last_message_sender_id = me,
    last_message_type = 'text',
    last_system_event = NULL,
    last_system_payload = NULL,
    updated_at = now()
  WHERE id = p_conversation_id;

  UPDATE public.group_conversation_members
  SET last_read_at = now()
  WHERE conversation_id = p_conversation_id
    AND user_id = me
    AND left_at IS NULL;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION public.send_group_message(uuid, text) IS
  'Send a text group message. Rate-limited (60/60s). Active membership required. Pickup-linked chats also require live organizer/approved authorization.';

REVOKE ALL ON FUNCTION public.send_group_message(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.send_group_message(uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.send_group_message(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.send_group_message(uuid, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 3) send_direct_message — Phase A preferred path (INSERT still allowed)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.send_direct_message(
  p_conversation_id uuid,
  p_body text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_body text := btrim(coalesce(p_body, ''));
  v_id uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.' USING ERRCODE = '42501';
  END IF;

  PERFORM public.assert_rpc_rate_limit('send_direct_message', 60, 60);

  IF p_conversation_id IS NULL THEN
    RAISE EXCEPTION 'conversation required' USING ERRCODE = '22023';
  END IF;

  IF char_length(v_body) < 1 THEN
    RAISE EXCEPTION 'Message body required.' USING ERRCODE = '22023';
  END IF;

  IF NOT public.direct_message_send_allowed(p_conversation_id, me) THEN
    RAISE EXCEPTION 'Not allowed to send in this conversation.'
      USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.direct_messages (conversation_id, sender_id, body)
  VALUES (p_conversation_id, me, v_body)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION public.send_direct_message(uuid, text) IS
  'Phase A preferred DM send path: rate-limited (60/60s), sender=auth.uid(), gated by direct_message_send_allowed. Named args: p_conversation_id, p_body. Authenticated direct INSERT remains available until 20260915_0005b.';

REVOKE ALL ON FUNCTION public.send_direct_message(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.send_direct_message(uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.send_direct_message(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.send_direct_message(uuid, text) TO service_role;

-- PHASE A: intentionally does NOT drop INSERT policies or REVOKE INSERT.
-- Old clients continue to use PostgREST insert under existing RLS.

-- ---------------------------------------------------------------------------
-- 4) friendship_ensure_pending — rate limit
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.friendship_ensure_pending(p_addressee uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  fid uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  PERFORM public.assert_rpc_rate_limit('friendship_ensure_pending', 30, 3600);

  IF p_addressee IS NULL OR p_addressee = me THEN
    RAISE EXCEPTION 'You cannot add yourself.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.blocked_users b
    WHERE (b.blocker_user_id = me AND b.blocked_user_id = p_addressee)
       OR (b.blocker_user_id = p_addressee AND b.blocked_user_id = me)
  ) THEN
    RAISE EXCEPTION 'You can''t send a friend request to this user.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.friendships f
    WHERE f.status IN ('pending', 'accepted')
      AND (
        (f.requester_id = me AND f.addressee_id = p_addressee)
        OR (f.requester_id = p_addressee AND f.addressee_id = me)
      )
  ) THEN
    RAISE EXCEPTION 'Friend request already exists.';
  END IF;

  SELECT f.id INTO fid
  FROM public.friendships f
  WHERE f.requester_id = me
    AND f.addressee_id = p_addressee
    AND f.status = 'declined'
    AND f.addressee_cleared_at IS NOT NULL
  LIMIT 1;

  IF fid IS NOT NULL THEN
    UPDATE public.friendships
    SET
      status = 'pending',
      responded_at = NULL,
      addressee_cleared_at = NULL,
      requester_cleared_at = NULL
    WHERE id = fid;
    RETURN fid;
  END IF;

  SELECT f.id INTO fid
  FROM public.friendships f
  WHERE f.requester_id = me
    AND f.addressee_id = p_addressee
    AND f.status = 'cancelled'
  LIMIT 1;

  IF fid IS NOT NULL THEN
    UPDATE public.friendships
    SET
      status = 'pending',
      responded_at = NULL,
      addressee_cleared_at = NULL,
      requester_cleared_at = NULL
    WHERE id = fid;
    RETURN fid;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.friendships f
    WHERE f.requester_id = me
      AND f.addressee_id = p_addressee
      AND f.status = 'declined'
      AND f.addressee_cleared_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Friend request already exists.';
  END IF;

  INSERT INTO public.friendships (requester_id, addressee_id, status)
  VALUES (me, p_addressee, 'pending')
  RETURNING id INTO fid;

  RETURN fid;
END;
$$;

REVOKE ALL ON FUNCTION public.friendship_ensure_pending(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.friendship_ensure_pending(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.friendship_ensure_pending(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.friendship_ensure_pending(uuid) TO service_role;

COMMENT ON FUNCTION public.friendship_ensure_pending(uuid) IS
  'Send or revive pending friend request; supports revival from declined (after addressee clear) or cancelled. Rate-limited (30/hour).';

-- ---------------------------------------------------------------------------
-- 5) poke_profile — rate limit
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.poke_profile(p_target_user_id uuid)
RETURNS TABLE (
  poke_id uuid,
  created_at timestamptz,
  viewer_can_poke_now boolean,
  viewer_cooldown_ends_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  last_poke_at timestamptz;
  cooldown_ends timestamptz;
  inserted public.profile_pokes%ROWTYPE;
  cooldown_interval interval := interval '5 minutes';
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  PERFORM public.assert_rpc_rate_limit('poke_profile', 60, 3600);

  IF p_target_user_id IS NULL THEN
    RAISE EXCEPTION 'Target user is required.';
  END IF;

  IF p_target_user_id = me THEN
    RAISE EXCEPTION 'You cannot poke yourself.';
  END IF;

  IF NOT public.profile_pokes_is_pokeable_fan(me) THEN
    RAISE EXCEPTION 'Your account cannot send pokes right now.';
  END IF;

  IF NOT public.profile_pokes_is_pokeable_fan(p_target_user_id) THEN
    RAISE EXCEPTION 'This profile cannot receive pokes.';
  END IF;

  IF public.profile_pokes_is_block_between(me, p_target_user_id) THEN
    RAISE EXCEPTION 'You cannot poke this user.';
  END IF;

  SELECT pp.created_at
  INTO last_poke_at
  FROM public.profile_pokes pp
  WHERE pp.poker_user_id = me
    AND pp.poked_user_id = p_target_user_id
  ORDER BY pp.created_at DESC
  LIMIT 1;

  IF last_poke_at IS NOT NULL THEN
    cooldown_ends := last_poke_at + cooldown_interval;
    IF cooldown_ends > now() THEN
      RETURN QUERY
      SELECT
        NULL::uuid,
        NULL::timestamptz,
        false,
        cooldown_ends;
      RETURN;
    END IF;
  END IF;

  INSERT INTO public.profile_pokes (poker_user_id, poked_user_id, source)
  VALUES (me, p_target_user_id, 'profile')
  RETURNING * INTO inserted;

  cooldown_ends := inserted.created_at + cooldown_interval;

  RETURN QUERY
  SELECT
    inserted.id,
    inserted.created_at,
    false,
    cooldown_ends;
END;
$$;

REVOKE ALL ON FUNCTION public.poke_profile(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.poke_profile(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.poke_profile(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.poke_profile(uuid) TO service_role;

COMMENT ON FUNCTION public.poke_profile(uuid) IS
  'Authenticated fan pokes a profile. Enforces blocks, active non-business profiles, 5-minute per-pair cooldown, and global rate limit (60/hour).';

-- ---------------------------------------------------------------------------
-- 6) report_group_message — rate limit
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.report_group_message(
  p_message_id uuid,
  p_category text DEFAULT NULL,
  p_details text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_msg public.group_messages%ROWTYPE;
  v_id uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  PERFORM public.assert_rpc_rate_limit('report_group_message', 30, 3600);

  SELECT * INTO v_msg
  FROM public.group_messages
  WHERE id = p_message_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Message not found.';
  END IF;

  IF v_msg.message_type IS DISTINCT FROM 'text' THEN
    RAISE EXCEPTION 'Cannot report system messages.';
  END IF;

  IF v_msg.sender_id = me THEN
    RAISE EXCEPTION 'Cannot report your own message.';
  END IF;

  IF NOT public.group_member_can_read_message(v_msg.conversation_id, me, v_msg.created_at) THEN
    RAISE EXCEPTION 'Not authorized to report this message.';
  END IF;

  IF NOT public.is_active_group_member(v_msg.conversation_id, me) THEN
    RAISE EXCEPTION 'Not an active member.';
  END IF;

  INSERT INTO public.group_message_reports (
    reporter_user_id,
    reported_user_id,
    message_id,
    conversation_id,
    message_text_snapshot,
    category,
    details
  ) VALUES (
    me,
    v_msg.sender_id,
    v_msg.id,
    v_msg.conversation_id,
    left(v_msg.body, 500),
    nullif(btrim(coalesce(p_category, '')), ''),
    nullif(btrim(coalesce(p_details, '')), '')
  )
  RETURNING id INTO v_id;

  UPDATE public.group_messages
  SET report_count = coalesce(report_count, 0) + 1
  WHERE id = v_msg.id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.report_group_message(uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.report_group_message(uuid, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.report_group_message(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_group_message(uuid, text, text) TO service_role;

COMMENT ON FUNCTION public.report_group_message(uuid, text, text) IS
  'Report a group text message. Rate-limited (30/hour). Active member with read access required.';

NOTIFY pgrst, 'reload schema';

COMMIT;
