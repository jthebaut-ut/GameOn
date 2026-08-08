-- =============================================================================
-- 20260925_0001 — Profile poke APNs push (trusted server path)
-- =============================================================================
-- After public.poke_profile successfully INSERTs a poke, queue notify-poke via
-- pg_net + Vault (same pattern as friend-request / chat push).
--
-- Preserves:
--   • SECURITY DEFINER + auth.uid() poker identity
--   • profile_pokes_is_pokeable_fan checks
--   • profile_pokes_is_block_between checks
--   • 5-minute per-pair cooldown (no push on cooldown no-op)
--   • assert_rpc_rate_limit('poke_profile', 60, 3600)
--   • RLS INSERT rules (no new client INSERT grants)
--
-- Do NOT apply from the agent; review and apply deliberately in Supabase.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Preference column (default on)
-- ---------------------------------------------------------------------------
ALTER TABLE public.user_notification_preferences
  ADD COLUMN IF NOT EXISTS poke_notifications_enabled boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.user_notification_preferences.poke_notifications_enabled IS
  'When false, user must not receive poke APNs. Defaults to true.';

-- ---------------------------------------------------------------------------
-- 2) Dedupe ledger — one logical delivery per poke row
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.profile_poke_push_deliveries (
  poke_id uuid NOT NULL PRIMARY KEY
    REFERENCES public.profile_pokes (id) ON DELETE CASCADE,
  recipient_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  poker_user_id uuid NOT NULL,
  delivery_status text NOT NULL DEFAULT 'queued'
    CHECK (delivery_status IN ('queued', 'sent', 'skipped', 'failed')),
  skip_reason text,
  sent_token_count integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS profile_poke_push_deliveries_recipient_created_idx
  ON public.profile_poke_push_deliveries (recipient_user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS profile_poke_push_deliveries_poker_created_idx
  ON public.profile_poke_push_deliveries (poker_user_id, created_at DESC);

COMMENT ON TABLE public.profile_poke_push_deliveries IS
  'Dedupe ledger for poke APNs. PK is profile_pokes.id (one logical delivery per poke).';

ALTER TABLE public.profile_poke_push_deliveries ENABLE ROW LEVEL SECURITY;
-- No authenticated policies — service_role bypasses RLS.
GRANT ALL ON public.profile_poke_push_deliveries TO service_role;

-- ---------------------------------------------------------------------------
-- 3) Queue Edge Function (best-effort; never fails the poke)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.queue_profile_poke_push_notification(
  p_poke_id uuid
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
  IF p_poke_id IS NULL THEN
    RETURN;
  END IF;

  IF to_regnamespace('net') IS NULL OR to_regclass('vault.decrypted_secrets') IS NULL THEN
    RAISE NOTICE 'poke push skipped: pg_net or vault unavailable';
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
    RAISE NOTICE 'poke push skipped: vault secrets missing';
    RETURN;
  END IF;

  SELECT decrypted_secret
  INTO v_cron_secret
  FROM vault.decrypted_secrets
  WHERE name = 'POKE_PUSH_CRON_SECRET'
    AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
  ORDER BY updated_at DESC NULLS LAST, created_at DESC
  LIMIT 1;

  v_headers := jsonb_build_object(
  'Content-Type', 'application/json',
  'Authorization', 'Bearer ' || v_service_role_key
);

IF v_cron_secret IS NOT NULL THEN
  v_headers := v_headers || jsonb_build_object(
    'x-cron-secret',
    v_cron_secret
  );
END IF;

  PERFORM net.http_post(
    url := v_url || '/functions/v1/notify-poke',
    headers := v_headers,
    body := jsonb_build_object(
      'poke_id', p_poke_id
    ),
    timeout_milliseconds := 15000
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'poke push queue failed: %', SQLERRM;
END;
$$;

REVOKE ALL ON FUNCTION public.queue_profile_poke_push_notification(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.queue_profile_poke_push_notification(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.queue_profile_poke_push_notification(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.queue_profile_poke_push_notification(uuid) TO service_role;

COMMENT ON FUNCTION public.queue_profile_poke_push_notification(uuid) IS
  'Best-effort async invoke of notify-poke with format-aware auth headers. Never raises to callers.';

-- ---------------------------------------------------------------------------
-- 4) Hook poke_profile — preserve all business logic + rate limit
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

  -- Queue APNs only after a real poke row exists (never on cooldown no-op).
  PERFORM public.queue_profile_poke_push_notification(inserted.id);

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
  'Authenticated fan pokes a profile. Enforces blocks, active non-business profiles, 5-minute per-pair cooldown, and global rate limit (60/hour). Queues APNs via notify-poke after insert.';

COMMIT;

-- =============================================================================
-- PRE-DEPLOYMENT VERIFICATION (run manually before apply)
-- =============================================================================
-- SELECT to_regprocedure('public.poke_profile(uuid)') IS NOT NULL;
-- SELECT pg_get_functiondef('public.poke_profile(uuid)'::regprocedure)
--   ILIKE '%assert_rpc_rate_limit%poke_profile%60%3600%';
-- SELECT to_regprocedure('public.push_worker_auth_headers(text, text)') IS NOT NULL;
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
-- SELECT to_regprocedure('public.queue_profile_poke_push_notification(uuid)') IS NOT NULL;
-- SELECT to_regclass('public.profile_poke_push_deliveries') IS NOT NULL;
-- SELECT column_name FROM information_schema.columns
--  WHERE table_schema='public' AND table_name='user_notification_preferences'
--    AND column_name = 'poke_notifications_enabled';
-- SELECT pg_get_functiondef('public.poke_profile(uuid)'::regprocedure)
--   ILIKE '%queue_profile_poke_push_notification%';
-- SELECT pg_get_functiondef('public.poke_profile(uuid)'::regprocedure)
--   ILIKE '%assert_rpc_rate_limit%';
--
-- ROLLBACK (reasonable)
-- =============================================================================
-- BEGIN;
-- -- Restore poke_profile from 20260915_0005a (without queue), then:
-- DROP FUNCTION IF EXISTS public.queue_profile_poke_push_notification(uuid);
-- DROP TABLE IF EXISTS public.profile_poke_push_deliveries;
-- ALTER TABLE public.user_notification_preferences
--   DROP COLUMN IF EXISTS poke_notifications_enabled;
-- COMMIT;
-- =============================================================================
