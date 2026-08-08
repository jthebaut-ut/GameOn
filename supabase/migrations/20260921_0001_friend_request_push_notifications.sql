-- =============================================================================
-- 20260921_0001 — Friend-request APNs push (trusted server path)
-- =============================================================================
-- After public.friendship_ensure_pending creates/revives a pending row, queue
-- notify-friend-request via pg_net + Vault (same pattern as DM / support-reply).
--
-- Preserves:
--   • SECURITY DEFINER + auth.uid() requester
--   • block checks
--   • pending/accepted conflict checks
--   • declined/cancelled revive rules
--   • assert_rpc_rate_limit('friendship_ensure_pending', 30, 3600)
--   • RLS SELECT-only for authenticated (no new INSERT grants)
--
-- Do NOT apply from the agent; review and apply deliberately in Supabase.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Preference column (default on)
-- ---------------------------------------------------------------------------
ALTER TABLE public.user_notification_preferences
  ADD COLUMN IF NOT EXISTS friend_request_notifications_enabled boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.user_notification_preferences.friend_request_notifications_enabled IS
  'When false, user must not receive friend-request APNs. Defaults to true.';

-- ---------------------------------------------------------------------------
-- 2) Dedupe ledger — one logical delivery per pending-event id
-- ---------------------------------------------------------------------------
-- event_id is generated at queue time so cancel→re-request (same friendship.id)
-- can notify again without colliding with a prior delivery for that row.
CREATE TABLE IF NOT EXISTS public.friend_request_push_deliveries (
  event_id uuid NOT NULL PRIMARY KEY,
  friendship_id uuid NOT NULL REFERENCES public.friendships (id) ON DELETE CASCADE,
  recipient_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  requester_user_id uuid NOT NULL,
  delivery_status text NOT NULL DEFAULT 'queued'
    CHECK (delivery_status IN ('queued', 'sent', 'skipped', 'failed')),
  skip_reason text,
  sent_token_count integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS friend_request_push_deliveries_friendship_created_idx
  ON public.friend_request_push_deliveries (friendship_id, created_at DESC);

CREATE INDEX IF NOT EXISTS friend_request_push_deliveries_recipient_created_idx
  ON public.friend_request_push_deliveries (recipient_user_id, created_at DESC);

COMMENT ON TABLE public.friend_request_push_deliveries IS
  'Dedupe ledger for friend-request APNs. PK is per-pending-event id (allows re-notify on revive).';

ALTER TABLE public.friend_request_push_deliveries ENABLE ROW LEVEL SECURITY;
-- No authenticated policies — service_role bypasses RLS.
GRANT ALL ON public.friend_request_push_deliveries TO service_role;

-- ---------------------------------------------------------------------------
-- 3) Queue Edge Function (best-effort; never fails the friend request)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.queue_friend_request_push_notification(
  p_friendship_id uuid,
  p_event_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_url text;
  v_service_role_key text;
  v_cron_secret text;
  v_headers jsonb;
BEGIN
  IF p_friendship_id IS NULL OR p_event_id IS NULL THEN
    RETURN;
  END IF;

  IF to_regnamespace('net') IS NULL OR to_regclass('vault.decrypted_secrets') IS NULL THEN
    RAISE NOTICE 'friend request push skipped: pg_net or vault unavailable';
    RETURN;
  END IF;

  SELECT rtrim(decrypted_secret, '/')
  INTO v_url
  FROM vault.decrypted_secrets
  WHERE name IN ('fangeo_supabase_url', 'SUPABASE_URL')
    AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
  ORDER BY CASE name WHEN 'fangeo_supabase_url' THEN 0 ELSE 1 END
  LIMIT 1;

  SELECT decrypted_secret
  INTO v_service_role_key
  FROM vault.decrypted_secrets
  WHERE name IN ('SUPABASE_SERVICE_ROLE_KEY', 'fangeo_service_role_key')
    AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
  ORDER BY CASE name WHEN 'SUPABASE_SERVICE_ROLE_KEY' THEN 0 ELSE 1 END
  LIMIT 1;

  IF v_url IS NULL OR v_service_role_key IS NULL THEN
    RAISE NOTICE 'friend request push skipped: vault secrets missing';
    RETURN;
  END IF;

  SELECT decrypted_secret
  INTO v_cron_secret
  FROM vault.decrypted_secrets
  WHERE name = 'FRIEND_REQUEST_PUSH_CRON_SECRET'
    AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
  ORDER BY updated_at DESC NULLS LAST, created_at DESC
  LIMIT 1;

  v_headers := jsonb_build_object(
    'Content-Type', 'application/json',
    'Authorization', 'Bearer ' || v_service_role_key
  );

  IF v_cron_secret IS NOT NULL THEN
    v_headers := v_headers || jsonb_build_object('x-cron-secret', v_cron_secret);
  END IF;

  PERFORM net.http_post(
    url := v_url || '/functions/v1/notify-friend-request',
    headers := v_headers,
    body := jsonb_build_object(
      'friendship_id', p_friendship_id,
      'event_id', p_event_id
    ),
    timeout_milliseconds := 15000
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'friend request push queue failed: %', SQLERRM;
END;
$$;

REVOKE ALL ON FUNCTION public.queue_friend_request_push_notification(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.queue_friend_request_push_notification(uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.queue_friend_request_push_notification(uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.queue_friend_request_push_notification(uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.queue_friend_request_push_notification(uuid, uuid) IS
  'Best-effort async invoke of notify-friend-request. Never raises to callers.';

-- ---------------------------------------------------------------------------
-- 4) Hook friendship_ensure_pending — preserve all business logic + rate limit
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
  v_event_id uuid;
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

    v_event_id := gen_random_uuid();
    PERFORM public.queue_friend_request_push_notification(fid, v_event_id);
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

    v_event_id := gen_random_uuid();
    PERFORM public.queue_friend_request_push_notification(fid, v_event_id);
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

  v_event_id := gen_random_uuid();
  PERFORM public.queue_friend_request_push_notification(fid, v_event_id);

  RETURN fid;
END;
$$;

REVOKE ALL ON FUNCTION public.friendship_ensure_pending(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.friendship_ensure_pending(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.friendship_ensure_pending(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.friendship_ensure_pending(uuid) TO service_role;

COMMENT ON FUNCTION public.friendship_ensure_pending(uuid) IS
  'Send or revive pending friend request; supports revival from declined (after addressee clear) or cancelled. Rate-limited (30/hour). Queues APNs via notify-friend-request after pending is established.';

COMMIT;

-- =============================================================================
-- PRE-DEPLOYMENT VERIFICATION (run manually before apply)
-- =============================================================================
-- SELECT to_regprocedure('public.friendship_ensure_pending(uuid)') IS NOT NULL;
-- SELECT pg_get_functiondef('public.friendship_ensure_pending(uuid)'::regprocedure)
--   ILIKE '%assert_rpc_rate_limit%friendship_ensure_pending%30%3600%';
-- SELECT to_regnamespace('net') IS NOT NULL AS pg_net_ready;
-- SELECT EXISTS (
--   SELECT 1 FROM vault.decrypted_secrets
--   WHERE name IN ('fangeo_supabase_url','SUPABASE_URL')
-- ) AS url_secret;
-- SELECT EXISTS (
--   SELECT 1 FROM vault.decrypted_secrets
--   WHERE name IN ('fangeo_service_role_key','SUPABASE_SERVICE_ROLE_KEY')
-- ) AS sr_secret;
--
-- POST-DEPLOYMENT VERIFICATION
-- =============================================================================
-- SELECT to_regprocedure('public.queue_friend_request_push_notification(uuid, uuid)') IS NOT NULL;
-- SELECT to_regclass('public.friend_request_push_deliveries') IS NOT NULL;
-- SELECT column_name FROM information_schema.columns
--  WHERE table_schema='public' AND table_name='user_notification_preferences'
--    AND column_name = 'friend_request_notifications_enabled';
-- SELECT pg_get_functiondef('public.friendship_ensure_pending(uuid)'::regprocedure)
--   ILIKE '%queue_friend_request_push_notification%';
-- SELECT pg_get_functiondef('public.friendship_ensure_pending(uuid)'::regprocedure)
--   ILIKE '%assert_rpc_rate_limit%';
--
-- ROLLBACK (reasonable)
-- =============================================================================
-- BEGIN;
-- -- Restore friendship_ensure_pending from 20260915_0005a (without queue), then:
-- DROP FUNCTION IF EXISTS public.queue_friend_request_push_notification(uuid, uuid);
-- DROP TABLE IF EXISTS public.friend_request_push_deliveries;
-- ALTER TABLE public.user_notification_preferences
--   DROP COLUMN IF EXISTS friend_request_notifications_enabled;
-- COMMIT;
-- =============================================================================
