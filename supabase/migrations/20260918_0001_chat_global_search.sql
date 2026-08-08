-- =============================================================================
-- 20260918_0001 — Global chat search (conversations + authorized messages)
-- =============================================================================
-- Review-ready only. Do NOT apply from the agent.
--
-- SECURITY HARDENING (audit pass):
--   • Exact read-parity helpers for DM / group message visibility
--   • auth.uid() only — no caller-supplied user id / auth decisions
--   • Internal preview helper not executable by authenticated
--   • Structured / unrecognized __FG_ sentinels never fall through to raw body
--   • Query min 2 / max 100, control-char scrub, hard result caps
--   • Dedicated search rate-limit buckets via assert_rpc_rate_limit
--   • pg_trgm GIN on privacy-safe preview expression (not raw JSON bodies)
--   • Alias RPCs are SECURITY INVOKER wrappers
--
-- Public RPCs:
--   search_chat_conversations(p_query, p_limit)
--   search_chat_messages(p_query, p_conversation_id DEFAULT NULL, p_limit)
--   search_direct_messages / search_group_messages (aliases)
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 0) Required read-auth helpers (fail closed if missing)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regprocedure('public.is_direct_conversation_participant(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['is_direct_conversation_participant(uuid,uuid)'];
  END IF;
  IF to_regprocedure('public.direct_message_after_viewer_clear(uuid,timestamptz,uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['direct_message_after_viewer_clear(uuid,timestamptz,uuid)'];
  END IF;
  IF to_regprocedure('public.pickup_invite_users_are_unblocked(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['pickup_invite_users_are_unblocked(uuid,uuid)'];
  END IF;
  IF to_regprocedure('public.group_member_can_read_message(uuid,uuid,timestamptz)') IS NULL THEN
    v_missing := v_missing || ARRAY['group_member_can_read_message(uuid,uuid,timestamptz)'];
  END IF;
  IF to_regprocedure('public.group_viewer_can_see_sender_message(uuid,uuid,text)') IS NULL THEN
    v_missing := v_missing || ARRAY['group_viewer_can_see_sender_message(uuid,uuid,text)'];
  END IF;
  IF to_regprocedure('public.is_active_group_member(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['is_active_group_member(uuid,uuid)'];
  END IF;
  IF to_regprocedure('public.is_pickup_game_chat_authorized(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['is_pickup_game_chat_authorized(uuid,uuid)'];
  END IF;
  IF to_regprocedure('public.assert_rpc_rate_limit(text,int,int)') IS NULL THEN
    v_missing := v_missing || ARRAY['assert_rpc_rate_limit(text,int,int)'];
  END IF;

  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION
      '20260918_0001 prerequisite missing: %',
      array_to_string(v_missing, ', ');
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 1) Rate-limit allowlist — add dedicated chat-search buckets
-- ---------------------------------------------------------------------------
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
    'report_group_message',
    'search_chat_conversations',
    'search_chat_messages'
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
  'SECURITY DEFINER fixed-window rate limit with allowlisted buckets (includes search_chat_*). Raises generic 54000 rate_limit_exceeded. Not granted to authenticated clients.';

REVOKE ALL ON FUNCTION public.assert_rpc_rate_limit(text, int, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.assert_rpc_rate_limit(text, int, int) FROM anon;
REVOKE ALL ON FUNCTION public.assert_rpc_rate_limit(text, int, int) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.assert_rpc_rate_limit(text, int, int) TO service_role;

-- ---------------------------------------------------------------------------
-- 2) Privacy-safe preview (INTERNAL — not a client RPC)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.chat_search_safe_message_preview(p_body text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $$
DECLARE
  v_body text := coalesce(p_body, '');
  v_prefix text;
BEGIN
  IF v_body = '' THEN
    RETURN '';
  END IF;

  -- Recognized FanGeo sentinels → fixed labels only (never JSON / coords / IDs).
  IF position('__FG_LOCATION_SHARE_V1__' in v_body) > 0 THEN
    RETURN 'Shared a location';
  END IF;
  IF position('__FG_LIVE_LOCATION_V1__' in v_body) > 0 THEN
    RETURN 'Started sharing live location';
  END IF;
  IF position('__FG_ON_MY_WAY_V1__' in v_body) > 0 THEN
    IF position('"status":"arrived"' in lower(v_body)) > 0
       OR position('"status": "arrived"' in lower(v_body)) > 0 THEN
      RETURN 'Arrived';
    END IF;
    RETURN 'Is on the way';
  END IF;
  IF position('__FG_POLL_V1__' in v_body) > 0 THEN
    RETURN 'Created a poll';
  END IF;
  IF position('__FG_PROFILE_SHARE_V1__' in v_body) > 0 THEN
    RETURN 'Shared a profile';
  END IF;
  IF position('__FG_PICKUP_SHARE_V1__' in v_body) > 0 THEN
    RETURN 'Shared a pickup game';
  END IF;
  IF position('__FG_PRO_SHARE_V1__' in v_body) > 0 THEN
    RETURN 'Shared a professional game';
  END IF;
  IF position('__FG_VENUE_SHARE_V1__' in v_body) > 0 THEN
    RETURN 'Shared a venue';
  END IF;

  -- Any other / malformed __FG_ payload: never fall through to raw body text.
  IF position('__FG_' in v_body) > 0 THEN
    RETURN 'Shared content';
  END IF;

  -- Plain text only (no structured sentinel present).
  v_prefix := btrim(v_body);
  IF v_prefix = '' THEN
    RETURN '';
  END IF;

  RETURN left(regexp_replace(v_prefix, E'[\\n\\r\\t]+', ' ', 'g'), 180);
END;
$$;

COMMENT ON FUNCTION public.chat_search_safe_message_preview(text) IS
  'INTERNAL. Privacy-safe chat search preview. Recognized sentinels → fixed labels; unrecognized __FG_ → generic label; never returns coordinates/JSON/UUIDs.';

REVOKE ALL ON FUNCTION public.chat_search_safe_message_preview(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.chat_search_safe_message_preview(text) FROM anon;
REVOKE ALL ON FUNCTION public.chat_search_safe_message_preview(text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.chat_search_safe_message_preview(text) TO postgres;
GRANT EXECUTE ON FUNCTION public.chat_search_safe_message_preview(text) TO service_role;

-- ---------------------------------------------------------------------------
-- 3) Query normalization (INTERNAL)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.chat_search_normalize_query(p_query text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $$
DECLARE
  q text := coalesce(p_query, '');
BEGIN
  -- Strip C0 controls + DEL, then normalize whitespace / leading @handles.
  q := regexp_replace(q, E'[\\x00-\\x1F\\x7F]', '', 'g');
  q := lower(btrim(q));
  q := regexp_replace(q, '^@+', '');
  q := regexp_replace(q, '\s+', ' ', 'g');

  IF char_length(q) > 100 THEN
    q := left(q, 100);
  END IF;

  IF char_length(q) < 2 THEN
    RETURN NULL;
  END IF;

  RETURN q;
END;
$$;

COMMENT ON FUNCTION public.chat_search_normalize_query(text) IS
  'INTERNAL. Min length 2, max 100, control-char scrub. Returns NULL when query is unusable.';

REVOKE ALL ON FUNCTION public.chat_search_normalize_query(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.chat_search_normalize_query(text) FROM anon;
REVOKE ALL ON FUNCTION public.chat_search_normalize_query(text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.chat_search_normalize_query(text) TO postgres;
GRANT EXECUTE ON FUNCTION public.chat_search_normalize_query(text) TO service_role;

-- ---------------------------------------------------------------------------
-- 4) Exact authorization parity helpers (INTERNAL)
--     Compose the same authoritative helpers used by ordinary message reads.
--     Own sent messages: allowed when conversation is authorized (sender = viewer
--     bypasses block hide, matching group_viewer_can_see_sender_message).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.chat_search_viewer_can_read_direct_message(
  p_conversation_id uuid,
  p_sender_id uuid,
  p_created_at timestamptz,
  p_deleted_at timestamptz,
  p_is_deleted boolean,
  p_viewer uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    p_viewer IS NOT NULL
    AND p_conversation_id IS NOT NULL
    AND p_created_at IS NOT NULL
    AND public.is_direct_conversation_participant(p_conversation_id, p_viewer)
    AND p_deleted_at IS NULL
    AND COALESCE(p_is_deleted, false) = false
    AND public.direct_message_after_viewer_clear(p_conversation_id, p_created_at, p_viewer)
    AND (
      p_sender_id IS NULL
      OR p_sender_id = p_viewer
      OR public.pickup_invite_users_are_unblocked(p_viewer, p_sender_id)
    );
$$;

COMMENT ON FUNCTION public.chat_search_viewer_can_read_direct_message(uuid, uuid, timestamptz, timestamptz, boolean, uuid) IS
  'INTERNAL. DM search visibility = participant + clear watermark + not deleted/moderated + block parity (own messages always visible to sender).';

REVOKE ALL ON FUNCTION public.chat_search_viewer_can_read_direct_message(uuid, uuid, timestamptz, timestamptz, boolean, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.chat_search_viewer_can_read_direct_message(uuid, uuid, timestamptz, timestamptz, boolean, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.chat_search_viewer_can_read_direct_message(uuid, uuid, timestamptz, timestamptz, boolean, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.chat_search_viewer_can_read_direct_message(uuid, uuid, timestamptz, timestamptz, boolean, uuid) TO postgres;
GRANT EXECUTE ON FUNCTION public.chat_search_viewer_can_read_direct_message(uuid, uuid, timestamptz, timestamptz, boolean, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.chat_search_viewer_can_read_group_message(
  p_conversation_id uuid,
  p_sender_id uuid,
  p_message_type text,
  p_created_at timestamptz,
  p_deleted_at timestamptz,
  p_is_deleted boolean,
  p_pickup_game_id uuid,
  p_viewer uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    p_viewer IS NOT NULL
    AND p_conversation_id IS NOT NULL
    AND p_created_at IS NOT NULL
    AND public.group_member_can_read_message(p_conversation_id, p_viewer, p_created_at)
    AND p_deleted_at IS NULL
    AND COALESCE(p_is_deleted, false) = false
    AND public.group_viewer_can_see_sender_message(p_viewer, p_sender_id, p_message_type)
    AND (
      p_pickup_game_id IS NULL
      OR public.is_pickup_game_chat_authorized(p_pickup_game_id, p_viewer)
    );
$$;

COMMENT ON FUNCTION public.chat_search_viewer_can_read_group_message(uuid, uuid, text, timestamptz, timestamptz, boolean, uuid, uuid) IS
  'INTERNAL. Group/pickup search visibility = membership window + deleted hide + sender block visibility + pickup auth. Matches group_messages SELECT (+ pickup live gate).';

REVOKE ALL ON FUNCTION public.chat_search_viewer_can_read_group_message(uuid, uuid, text, timestamptz, timestamptz, boolean, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.chat_search_viewer_can_read_group_message(uuid, uuid, text, timestamptz, timestamptz, boolean, uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.chat_search_viewer_can_read_group_message(uuid, uuid, text, timestamptz, timestamptz, boolean, uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.chat_search_viewer_can_read_group_message(uuid, uuid, text, timestamptz, timestamptz, boolean, uuid, uuid) TO postgres;
GRANT EXECUTE ON FUNCTION public.chat_search_viewer_can_read_group_message(uuid, uuid, text, timestamptz, timestamptz, boolean, uuid, uuid) TO service_role;

-- Conversation exists-for-search only AFTER authorization (no UUID type oracle).
CREATE OR REPLACE FUNCTION public.chat_search_viewer_can_access_conversation(
  p_conversation_id uuid,
  p_viewer uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    p_viewer IS NOT NULL
    AND p_conversation_id IS NOT NULL
    AND (
      public.is_direct_conversation_participant(p_conversation_id, p_viewer)
      OR (
        public.is_active_group_member(p_conversation_id, p_viewer)
        AND EXISTS (
          SELECT 1
          FROM public.group_conversations c
          WHERE c.id = p_conversation_id
            AND (
              c.pickup_game_id IS NULL
              OR public.is_pickup_game_chat_authorized(c.pickup_game_id, p_viewer)
            )
        )
      )
      -- Left members may still message-search within membership window (SELECT parity)
      -- when scoping by conversation id, without revealing whether the id is DM vs group.
      OR EXISTS (
        SELECT 1
        FROM public.group_conversations c
        WHERE c.id = p_conversation_id
          AND EXISTS (
            SELECT 1
            FROM public.group_conversation_members m
            WHERE m.conversation_id = c.id
              AND m.user_id = p_viewer
          )
          AND (
            c.pickup_game_id IS NULL
            OR public.is_pickup_game_chat_authorized(c.pickup_game_id, p_viewer)
          )
      )
    );
$$;

COMMENT ON FUNCTION public.chat_search_viewer_can_access_conversation(uuid, uuid) IS
  'INTERNAL. True only when viewer is authorized for the conversation. Never distinguishes DM vs group to callers.';

REVOKE ALL ON FUNCTION public.chat_search_viewer_can_access_conversation(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.chat_search_viewer_can_access_conversation(uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.chat_search_viewer_can_access_conversation(uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.chat_search_viewer_can_access_conversation(uuid, uuid) TO postgres;
GRANT EXECUTE ON FUNCTION public.chat_search_viewer_can_access_conversation(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 5) pg_trgm indexes on privacy-safe preview (not raw structured JSON)
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA extensions;

CREATE INDEX IF NOT EXISTS direct_messages_safe_preview_trgm_idx
  ON public.direct_messages
  USING gin ((public.chat_search_safe_message_preview(body)) extensions.gin_trgm_ops)
  WHERE deleted_at IS NULL
    AND COALESCE(is_deleted, false) = false;

CREATE INDEX IF NOT EXISTS group_messages_safe_preview_trgm_idx
  ON public.group_messages
  USING gin ((public.chat_search_safe_message_preview(body)) extensions.gin_trgm_ops)
  WHERE deleted_at IS NULL
    AND COALESCE(is_deleted, false) = false
    AND COALESCE(message_type, 'text') = 'text';

COMMENT ON INDEX public.direct_messages_safe_preview_trgm_idx IS
  'Trigram index over privacy-safe preview expression only — never indexes raw location/poll JSON.';
COMMENT ON INDEX public.group_messages_safe_preview_trgm_idx IS
  'Trigram index over privacy-safe preview expression only — never indexes raw location/poll JSON.';

-- ---------------------------------------------------------------------------
-- 6) Conversations (names / titles the caller can access)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.search_chat_conversations(text, integer);

CREATE OR REPLACE FUNCTION public.search_chat_conversations(
  p_query text,
  p_limit integer DEFAULT 25
)
RETURNS TABLE (
  conversation_id uuid,
  conversation_kind text,
  title text,
  subtitle text,
  peer_user_id uuid,
  pickup_game_id uuid,
  avatar_url text,
  avatar_thumbnail_url text,
  unread_count integer,
  last_message_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  q text;
  lim int := least(greatest(coalesce(p_limit, 25), 1), 50);
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.' USING ERRCODE = '42501';
  END IF;

  PERFORM public.assert_rpc_rate_limit('search_chat_conversations', 30, 60);

  q := public.chat_search_normalize_query(p_query);
  IF q IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH
  dm AS (
    SELECT
      dc.id AS conversation_id,
      CASE
        WHEN dc.business_id IS NOT NULL OR dc.venue_id IS NOT NULL THEN 'business'
        ELSE 'direct'
      END AS conversation_kind,
      CASE
        WHEN dc.venue_id IS NOT NULL THEN coalesce(nullif(btrim(v.venue_name), ''), nullif(btrim(b.display_name), ''), 'Business')
        WHEN dc.business_id IS NOT NULL THEN coalesce(nullif(btrim(b.display_name), ''), 'Business')
        ELSE coalesce(
          nullif(btrim(up.display_name), ''),
          nullif(btrim(up.username), ''),
          'Fan'
        )
      END AS title,
      CASE
        WHEN dc.venue_id IS NOT NULL OR dc.business_id IS NOT NULL THEN
          coalesce(nullif(btrim(b.business_handle), ''), nullif(btrim(b.display_name), ''), 'Business')
        ELSE coalesce(nullif(btrim(up.username), ''), '')
      END AS subtitle,
      CASE
        WHEN dc.user_a_id = me THEN dc.user_b_id
        ELSE dc.user_a_id
      END AS peer_user_id,
      NULL::uuid AS pickup_game_id,
      CASE
        WHEN dc.business_id IS NOT NULL OR dc.venue_id IS NOT NULL THEN NULL
        ELSE coalesce(up.avatar_thumbnail_url, up.avatar_url)
      END AS avatar_url,
      CASE
        WHEN dc.business_id IS NOT NULL OR dc.venue_id IS NOT NULL THEN NULL
        ELSE up.avatar_thumbnail_url
      END AS avatar_thumbnail_url,
      0 AS unread_count,
      (
        SELECT max(dm.created_at)
        FROM public.direct_messages dm
        WHERE dm.conversation_id = dc.id
          AND public.chat_search_viewer_can_read_direct_message(
            dm.conversation_id,
            dm.sender_id,
            dm.created_at,
            dm.deleted_at,
            dm.is_deleted,
            me
          )
      ) AS last_message_at
    FROM public.direct_conversations dc
    LEFT JOIN public.user_profiles up
      ON up.id = CASE WHEN dc.user_a_id = me THEN dc.user_b_id ELSE dc.user_a_id END
    LEFT JOIN public.businesses b ON b.id = dc.business_id
    LEFT JOIN public.venues v ON v.id = dc.venue_id
    WHERE public.is_direct_conversation_participant(dc.id, me)
      AND public.pickup_invite_users_are_unblocked(
        me,
        CASE WHEN dc.user_a_id = me THEN dc.user_b_id ELSE dc.user_a_id END
      )
      AND (
        lower(coalesce(up.display_name, '')) LIKE '%' || q || '%'
        OR lower(coalesce(up.username, '')) LIKE '%' || q || '%'
        OR lower(coalesce(b.display_name, '')) LIKE '%' || q || '%'
        OR lower(coalesce(b.business_handle, '')) LIKE '%' || q || '%'
        OR lower(coalesce(v.venue_name, '')) LIKE '%' || q || '%'
      )
  ),
  grp AS (
    SELECT
      c.id AS conversation_id,
      CASE WHEN c.pickup_game_id IS NOT NULL THEN 'pickup' ELSE 'group' END AS conversation_kind,
      coalesce(nullif(btrim(c.title), ''), 'Group') AS title,
      CASE WHEN c.pickup_game_id IS NOT NULL THEN 'Pickup' ELSE 'Group' END AS subtitle,
      NULL::uuid AS peer_user_id,
      c.pickup_game_id,
      NULL::text AS avatar_url,
      NULL::text AS avatar_thumbnail_url,
      0 AS unread_count,
      c.last_message_at
    FROM public.group_conversations c
    WHERE public.is_active_group_member(c.id, me)
      AND (
        c.pickup_game_id IS NULL
        OR public.is_pickup_game_chat_authorized(c.pickup_game_id, me)
      )
      AND lower(coalesce(c.title, '')) LIKE '%' || q || '%'
  )
  SELECT *
  FROM (
    SELECT * FROM dm
    UNION ALL
    SELECT * FROM grp
  ) s
  ORDER BY s.last_message_at DESC NULLS LAST, s.title ASC
  LIMIT lim;
END;
$$;

COMMENT ON FUNCTION public.search_chat_conversations(text, integer) IS
  'Authorized conversation-name search. auth.uid() only. Rate-limited. Min query 2 / max 100.';

REVOKE ALL ON FUNCTION public.search_chat_conversations(text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.search_chat_conversations(text, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.search_chat_conversations(text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.search_chat_conversations(text, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 7) Messages (authorized safe-preview search; optional conversation scope)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.search_direct_messages(text, integer);
DROP FUNCTION IF EXISTS public.search_group_messages(text, integer);
DROP FUNCTION IF EXISTS public.search_chat_messages(text, uuid, integer);

CREATE OR REPLACE FUNCTION public.search_chat_messages(
  p_query text,
  p_conversation_id uuid DEFAULT NULL,
  p_limit integer DEFAULT 40
)
RETURNS TABLE (
  message_id uuid,
  conversation_id uuid,
  conversation_kind text,
  conversation_title text,
  peer_user_id uuid,
  pickup_game_id uuid,
  sender_id uuid,
  created_at timestamptz,
  safe_preview text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  q text;
  lim int := least(greatest(coalesce(p_limit, 40), 1), 80);
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.' USING ERRCODE = '42501';
  END IF;

  PERFORM public.assert_rpc_rate_limit('search_chat_messages', 40, 60);

  q := public.chat_search_normalize_query(p_query);
  IF q IS NULL THEN
    RETURN;
  END IF;

  -- Inaccessible / unknown conversation ids → zero rows (no existence / type oracle).
  IF p_conversation_id IS NOT NULL
     AND NOT public.chat_search_viewer_can_access_conversation(p_conversation_id, me) THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH
  dm AS (
    SELECT
      dm.id AS message_id,
      dm.conversation_id,
      CASE
        WHEN dc.business_id IS NOT NULL OR dc.venue_id IS NOT NULL THEN 'business'
        ELSE 'direct'
      END AS conversation_kind,
      CASE
        WHEN dc.venue_id IS NOT NULL THEN coalesce(nullif(btrim(v.venue_name), ''), nullif(btrim(b.display_name), ''), 'Business')
        WHEN dc.business_id IS NOT NULL THEN coalesce(nullif(btrim(b.display_name), ''), 'Business')
        ELSE coalesce(
          nullif(btrim(up.display_name), ''),
          nullif(btrim(up.username), ''),
          'Fan'
        )
      END AS conversation_title,
      CASE WHEN dc.user_a_id = me THEN dc.user_b_id ELSE dc.user_a_id END AS peer_user_id,
      NULL::uuid AS pickup_game_id,
      dm.sender_id,
      dm.created_at,
      public.chat_search_safe_message_preview(dm.body) AS safe_preview
    FROM public.direct_messages dm
    INNER JOIN public.direct_conversations dc ON dc.id = dm.conversation_id
    LEFT JOIN public.user_profiles up
      ON up.id = CASE WHEN dc.user_a_id = me THEN dc.user_b_id ELSE dc.user_a_id END
    LEFT JOIN public.businesses b ON b.id = dc.business_id
    LEFT JOIN public.venues v ON v.id = dc.venue_id
    WHERE (p_conversation_id IS NULL OR dm.conversation_id = p_conversation_id)
      AND public.chat_search_viewer_can_read_direct_message(
        dm.conversation_id,
        dm.sender_id,
        dm.created_at,
        dm.deleted_at,
        dm.is_deleted,
        me
      )
      AND lower(public.chat_search_safe_message_preview(dm.body)) LIKE '%' || q || '%'
  ),
  grp AS (
    SELECT
      gm.id AS message_id,
      gm.conversation_id,
      CASE WHEN c.pickup_game_id IS NOT NULL THEN 'pickup' ELSE 'group' END AS conversation_kind,
      coalesce(nullif(btrim(c.title), ''), 'Group') AS conversation_title,
      NULL::uuid AS peer_user_id,
      c.pickup_game_id,
      gm.sender_id,
      gm.created_at,
      public.chat_search_safe_message_preview(gm.body) AS safe_preview
    FROM public.group_messages gm
    INNER JOIN public.group_conversations c ON c.id = gm.conversation_id
    WHERE (p_conversation_id IS NULL OR gm.conversation_id = p_conversation_id)
      AND COALESCE(gm.message_type, 'text') = 'text'
      AND public.chat_search_viewer_can_read_group_message(
        gm.conversation_id,
        gm.sender_id,
        gm.message_type,
        gm.created_at,
        gm.deleted_at,
        gm.is_deleted,
        c.pickup_game_id,
        me
      )
      AND lower(public.chat_search_safe_message_preview(gm.body)) LIKE '%' || q || '%'
  )
  SELECT *
  FROM (
    SELECT * FROM dm
    UNION ALL
    SELECT * FROM grp
  ) s
  WHERE char_length(btrim(s.safe_preview)) > 0
  ORDER BY s.created_at DESC
  LIMIT lim;
END;
$$;

COMMENT ON FUNCTION public.search_chat_messages(text, uuid, integer) IS
  'Authorized message search over privacy-safe previews only. Optional p_conversation_id scopes without UUID oracle. Rate-limited. Includes own sent messages in authorized threads.';

REVOKE ALL ON FUNCTION public.search_chat_messages(text, uuid, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.search_chat_messages(text, uuid, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.search_chat_messages(text, uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.search_chat_messages(text, uuid, integer) TO service_role;

-- Compatibility aliases — SECURITY INVOKER (no elevated privileges; filter DEFINER results).
CREATE OR REPLACE FUNCTION public.search_direct_messages(
  p_query text,
  p_limit integer DEFAULT 40
)
RETURNS TABLE (
  message_id uuid,
  conversation_id uuid,
  conversation_kind text,
  conversation_title text,
  peer_user_id uuid,
  pickup_game_id uuid,
  sender_id uuid,
  created_at timestamptz,
  safe_preview text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT *
  FROM public.search_chat_messages(p_query, NULL, p_limit)
  WHERE conversation_kind IN ('direct', 'business');
$$;

CREATE OR REPLACE FUNCTION public.search_group_messages(
  p_query text,
  p_limit integer DEFAULT 40
)
RETURNS TABLE (
  message_id uuid,
  conversation_id uuid,
  conversation_kind text,
  conversation_title text,
  peer_user_id uuid,
  pickup_game_id uuid,
  sender_id uuid,
  created_at timestamptz,
  safe_preview text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT *
  FROM public.search_chat_messages(p_query, NULL, p_limit)
  WHERE conversation_kind IN ('group', 'pickup');
$$;

REVOKE ALL ON FUNCTION public.search_direct_messages(text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.search_direct_messages(text, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.search_direct_messages(text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.search_direct_messages(text, integer) TO service_role;

REVOKE ALL ON FUNCTION public.search_group_messages(text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.search_group_messages(text, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.search_group_messages(text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.search_group_messages(text, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 8) Static privilege verification (migration-time)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF has_function_privilege(
    'authenticated',
    'public.chat_search_safe_message_preview(text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: authenticated can execute chat_search_safe_message_preview';
  END IF;
  IF has_function_privilege(
    'authenticated',
    'public.chat_search_normalize_query(text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: authenticated can execute chat_search_normalize_query';
  END IF;
  IF has_function_privilege(
    'authenticated',
    'public.chat_search_viewer_can_read_direct_message(uuid,uuid,timestamptz,timestamptz,boolean,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: authenticated can execute chat_search_viewer_can_read_direct_message';
  END IF;
  IF has_function_privilege(
    'authenticated',
    'public.chat_search_viewer_can_read_group_message(uuid,uuid,text,timestamptz,timestamptz,boolean,uuid,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: authenticated can execute chat_search_viewer_can_read_group_message';
  END IF;
  IF has_function_privilege(
    'authenticated',
    'public.chat_search_viewer_can_access_conversation(uuid,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: authenticated can execute chat_search_viewer_can_access_conversation';
  END IF;
  IF has_function_privilege(
    'authenticated',
    'public.assert_rpc_rate_limit(text,int,int)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: authenticated can execute assert_rpc_rate_limit';
  END IF;
  IF NOT has_function_privilege(
    'authenticated',
    'public.search_chat_conversations(text,integer)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: authenticated missing search_chat_conversations';
  END IF;
  IF NOT has_function_privilege(
    'authenticated',
    'public.search_chat_messages(text,uuid,integer)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: authenticated missing search_chat_messages';
  END IF;
  IF has_function_privilege(
    'anon',
    'public.search_chat_messages(text,uuid,integer)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: anon can execute search_chat_messages';
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
