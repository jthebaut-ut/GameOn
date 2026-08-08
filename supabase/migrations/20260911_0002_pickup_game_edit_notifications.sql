-- =============================================================================
-- 20260911_0002_pickup_game_edit_notifications.sql
-- REVIEW / MANUAL APPLY ONLY — do NOT auto-apply from the agent change set.
--
-- Meaningful pickup_games edits:
--   1) durable update event (deduped by fingerprint)
--   2) one system message in the private pickup chat (if it exists)
--   3) preference-gated APNs enqueue with durable delivery state
--
-- Irreversible additions (no CASCADE drops of app data):
--   - user_notification_preferences.pickup_game_change_notifications_enabled
--   - public.pickup_game_update_events
--   - public.pickup_game_update_push_deliveries
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Preference column (APNs gate only; chat history still shows system messages)
-- ---------------------------------------------------------------------------
ALTER TABLE public.user_notification_preferences
  ADD COLUMN IF NOT EXISTS pickup_game_change_notifications_enabled boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.user_notification_preferences.pickup_game_change_notifications_enabled IS
  'When false, user must not receive pickup-game edit/cancel push notifications. Defaults to true. Chat system messages are unaffected.';

-- ---------------------------------------------------------------------------
-- Durable edit events
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.pickup_game_update_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pickup_game_id uuid NOT NULL REFERENCES public.pickup_games(id) ON DELETE CASCADE,
  -- Nullable: auth.uid() when known; NULL for service-role/automated updates (never impersonate organizer).
  editor_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  fingerprint text NOT NULL,
  change_kinds text[] NOT NULL DEFAULT '{}',
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  chat_message_id uuid,
  push_delivery_status text NOT NULL DEFAULT 'pending'
    CHECK (push_delivery_status IN (
      'pending', 'queued', 'sending', 'sent', 'failed', 'retryable', 'skipped'
    )),
  push_attempt_count integer NOT NULL DEFAULT 0,
  push_queued_at timestamptz,
  push_attempted_at timestamptz,
  push_sent_at timestamptz,
  push_last_error text,
  push_skip_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (pickup_game_id, fingerprint)
);

-- Upgrade path if an earlier draft created NOT NULL editor_user_id / missing push columns.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'pickup_game_update_events'
      AND column_name = 'editor_user_id'
      AND is_nullable = 'NO'
  ) THEN
    ALTER TABLE public.pickup_game_update_events
      ALTER COLUMN editor_user_id DROP NOT NULL;
  END IF;
END $$;

ALTER TABLE public.pickup_game_update_events
  ADD COLUMN IF NOT EXISTS push_delivery_status text;
ALTER TABLE public.pickup_game_update_events
  ADD COLUMN IF NOT EXISTS push_attempt_count integer;
ALTER TABLE public.pickup_game_update_events
  ADD COLUMN IF NOT EXISTS push_queued_at timestamptz;
ALTER TABLE public.pickup_game_update_events
  ADD COLUMN IF NOT EXISTS push_attempted_at timestamptz;
ALTER TABLE public.pickup_game_update_events
  ADD COLUMN IF NOT EXISTS push_sent_at timestamptz;
ALTER TABLE public.pickup_game_update_events
  ADD COLUMN IF NOT EXISTS push_last_error text;
ALTER TABLE public.pickup_game_update_events
  ADD COLUMN IF NOT EXISTS push_skip_reason text;

UPDATE public.pickup_game_update_events
SET push_delivery_status = coalesce(nullif(btrim(push_delivery_status), ''), 'pending')
WHERE push_delivery_status IS NULL;

UPDATE public.pickup_game_update_events
SET push_attempt_count = coalesce(push_attempt_count, 0)
WHERE push_attempt_count IS NULL;

ALTER TABLE public.pickup_game_update_events
  ALTER COLUMN push_delivery_status SET DEFAULT 'pending';
ALTER TABLE public.pickup_game_update_events
  ALTER COLUMN push_delivery_status SET NOT NULL;
ALTER TABLE public.pickup_game_update_events
  ALTER COLUMN push_attempt_count SET DEFAULT 0;
ALTER TABLE public.pickup_game_update_events
  ALTER COLUMN push_attempt_count SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'pickup_game_update_events_push_delivery_status_check'
      AND conrelid = 'public.pickup_game_update_events'::regclass
  ) THEN
    ALTER TABLE public.pickup_game_update_events
      ADD CONSTRAINT pickup_game_update_events_push_delivery_status_check
      CHECK (push_delivery_status IN (
        'pending', 'queued', 'sending', 'sent', 'failed', 'retryable', 'skipped'
      ));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS pickup_game_update_events_game_created_idx
  ON public.pickup_game_update_events (pickup_game_id, created_at DESC);

CREATE INDEX IF NOT EXISTS pickup_game_update_events_push_retry_idx
  ON public.pickup_game_update_events (push_delivery_status, created_at ASC)
  WHERE push_delivery_status IN ('pending', 'queued', 'retryable', 'failed')
    AND push_sent_at IS NULL;

COMMENT ON TABLE public.pickup_game_update_events IS
  'Durable pickup edit/cancel events. Deduped by (pickup_game_id, fingerprint). Push delivery state is independent of chat insert success.';

COMMENT ON COLUMN public.pickup_game_update_events.editor_user_id IS
  'auth.uid() of the editor when the UPDATE ran under an authenticated session. NULL for service-role/automated updates — never substituted with the organizer.';

-- Per-recipient push receipts (one logical push per user per event).
CREATE TABLE IF NOT EXISTS public.pickup_game_update_push_deliveries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  update_event_id uuid NOT NULL REFERENCES public.pickup_game_update_events(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  token_id uuid,
  status text NOT NULL DEFAULT 'sent'
    CHECK (status IN ('sent', 'failed', 'skipped')),
  error_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (update_event_id, user_id)
);

CREATE INDEX IF NOT EXISTS pickup_game_update_push_deliveries_event_idx
  ON public.pickup_game_update_push_deliveries (update_event_id);

COMMENT ON TABLE public.pickup_game_update_push_deliveries IS
  'Idempotent per-recipient push receipts for pickup edit notifications. Retries skip users already marked sent.';

ALTER TABLE public.pickup_game_update_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pickup_game_update_push_deliveries ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.pickup_game_update_events FROM PUBLIC;
REVOKE ALL ON TABLE public.pickup_game_update_events FROM anon;
REVOKE ALL ON TABLE public.pickup_game_update_push_deliveries FROM PUBLIC;
REVOKE ALL ON TABLE public.pickup_game_update_push_deliveries FROM anon;
REVOKE ALL ON TABLE public.pickup_game_update_push_deliveries FROM authenticated;

GRANT SELECT ON TABLE public.pickup_game_update_events TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.pickup_game_update_events TO service_role;
GRANT SELECT, INSERT, UPDATE ON TABLE public.pickup_game_update_push_deliveries TO service_role;

DROP POLICY IF EXISTS pickup_game_update_events_select_participant
  ON public.pickup_game_update_events;
CREATE POLICY pickup_game_update_events_select_participant
  ON public.pickup_game_update_events
  FOR SELECT
  TO authenticated
  USING (
    public.is_pickup_game_chat_authorized(pickup_game_id, (SELECT auth.uid()))
    OR (editor_user_id IS NOT NULL AND editor_user_id = (SELECT auth.uid()))
  );

-- No authenticated INSERT/UPDATE/DELETE policies on events or deliveries.

-- ---------------------------------------------------------------------------
-- Pure helpers (not SECURITY DEFINER). Clients do not need EXECUTE.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pickup_norm_text(p text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT lower(btrim(regexp_replace(coalesce(p, ''), '\s+', ' ', 'g')));
$$;

CREATE OR REPLACE FUNCTION public.pickup_round_coord(p double precision)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN p IS NULL THEN ''
    ELSE to_char(round(p::numeric, 4), 'FM999999990.0000')
  END;
$$;

CREATE OR REPLACE FUNCTION public.pickup_location_place_text(
  p_address text,
  p_city text,
  p_state text
)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT concat_ws(
    '|',
    public.pickup_norm_text(p_address),
    public.pickup_norm_text(p_city),
    public.pickup_norm_text(p_state)
  );
$$;

CREATE OR REPLACE FUNCTION public.pickup_location_identity(
  p_address text,
  p_city text,
  p_state text,
  p_lat double precision,
  p_lon double precision
)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN nullif(
      replace(public.pickup_location_place_text(p_address, p_city, p_state), '|', ''),
      ''
    ) IS NOT NULL
    THEN public.pickup_location_place_text(p_address, p_city, p_state)
    ELSE concat_ws(
      '|',
      public.pickup_location_place_text(p_address, p_city, p_state),
      public.pickup_round_coord(p_lat),
      public.pickup_round_coord(p_lon)
    )
  END;
$$;

CREATE OR REPLACE FUNCTION public.pickup_location_label(
  p_address text,
  p_city text,
  p_state text
)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT nullif(
    array_to_string(
      ARRAY[
        nullif(btrim(coalesce(p_address, '')), ''),
        nullif(btrim(coalesce(p_city, '')), ''),
        nullif(btrim(coalesce(p_state, '')), '')
      ]::text[],
      ', '
    ),
    ''
  );
$$;

CREATE OR REPLACE FUNCTION public.pickup_meaningful_change_kinds(
  p_old public.pickup_games,
  p_new public.pickup_games
)
RETURNS text[]
LANGUAGE plpgsql
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_kinds text[] := ARRAY[]::text[];
BEGIN
  IF public.pickup_norm_text(p_old.title) IS DISTINCT FROM public.pickup_norm_text(p_new.title) THEN
    v_kinds := v_kinds || ARRAY['title'];
  END IF;
  IF public.pickup_norm_text(p_old.sport) IS DISTINCT FROM public.pickup_norm_text(p_new.sport)
     OR public.pickup_norm_text(p_old.game_format) IS DISTINCT FROM public.pickup_norm_text(p_new.game_format) THEN
    v_kinds := v_kinds || ARRAY['sport'];
  END IF;
  IF p_old.game_start_at IS DISTINCT FROM p_new.game_start_at THEN
    v_kinds := v_kinds || ARRAY['start'];
  END IF;
  IF p_old.end_time IS DISTINCT FROM p_new.end_time THEN
    v_kinds := v_kinds || ARRAY['end'];
  END IF;
  IF public.pickup_location_identity(
       p_old.address, p_old.city, p_old.state, p_old.latitude, p_old.longitude
     ) IS DISTINCT FROM public.pickup_location_identity(
       p_new.address, p_new.city, p_new.state, p_new.latitude, p_new.longitude
     ) THEN
    v_kinds := v_kinds || ARRAY['location'];
  END IF;
  IF p_old.players_needed IS DISTINCT FROM p_new.players_needed
     OR p_old.max_players IS DISTINCT FROM p_new.max_players THEN
    v_kinds := v_kinds || ARRAY['capacity'];
  END IF;
  IF public.pickup_norm_text(p_old.participant_preference)
       IS DISTINCT FROM public.pickup_norm_text(p_new.participant_preference)
     OR p_old.age_min IS DISTINCT FROM p_new.age_min
     OR p_old.age_max IS DISTINCT FROM p_new.age_max THEN
    v_kinds := v_kinds || ARRAY['welcome'];
  END IF;
  IF public.pickup_norm_text(p_old.skill_level) IS DISTINCT FROM public.pickup_norm_text(p_new.skill_level) THEN
    v_kinds := v_kinds || ARRAY['skill'];
  END IF;
  IF public.pickup_norm_text(p_old.play_environment)
       IS DISTINCT FROM public.pickup_norm_text(p_new.play_environment) THEN
    v_kinds := v_kinds || ARRAY['environment'];
  END IF;
  IF p_old.is_free IS DISTINCT FROM p_new.is_free
     OR coalesce(p_old.entry_fee_amount, 0) IS DISTINCT FROM coalesce(p_new.entry_fee_amount, 0) THEN
    v_kinds := v_kinds || ARRAY['cost'];
  END IF;
  IF public.pickup_norm_text(p_old.status) IS DISTINCT FROM public.pickup_norm_text(p_new.status) THEN
    v_kinds := v_kinds || ARRAY['status'];
  END IF;
  IF p_old.is_visible IS DISTINCT FROM p_new.is_visible THEN
    v_kinds := v_kinds || ARRAY['visibility'];
  END IF;
  RETURN v_kinds;
END;
$$;

-- ---------------------------------------------------------------------------
-- Queue Edge Function (best-effort; must not roll back pickup UPDATE)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.queue_pickup_game_change_push_notification(
  p_update_event_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_url text;
  v_service_role_key text;
  v_cron_secret text;
  v_headers jsonb;
  v_request_id bigint;
BEGIN
  IF p_update_event_id IS NULL THEN
    RETURN;
  END IF;

  IF to_regnamespace('net') IS NULL OR to_regclass('vault.decrypted_secrets') IS NULL THEN
    UPDATE public.pickup_game_update_events
    SET push_delivery_status = 'retryable',
        push_last_error = 'pg_net_or_vault_unavailable',
        push_attempt_count = push_attempt_count + 1,
        push_attempted_at = now()
    WHERE id = p_update_event_id
      AND push_sent_at IS NULL
      AND push_delivery_status IS DISTINCT FROM 'sent'
      AND push_delivery_status IS DISTINCT FROM 'skipped';
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
  WHERE name IN ('fangeo_service_role_key', 'SUPABASE_SERVICE_ROLE_KEY')
    AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
  ORDER BY CASE name WHEN 'fangeo_service_role_key' THEN 0 ELSE 1 END
  LIMIT 1;

  SELECT decrypted_secret
  INTO v_cron_secret
  FROM vault.decrypted_secrets
  WHERE name IN (
      'PICKUP_GAME_CHANGE_PUSH_CRON_SECRET',
      'FANGEO_ANNOUNCEMENT_PUSH_CRON_SECRET',
      'SUPPORT_REPLY_PUSH_CRON_SECRET'
    )
    AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
  ORDER BY CASE name
    WHEN 'PICKUP_GAME_CHANGE_PUSH_CRON_SECRET' THEN 0
    WHEN 'FANGEO_ANNOUNCEMENT_PUSH_CRON_SECRET' THEN 1
    ELSE 2
  END
  LIMIT 1;

  IF v_url IS NULL OR v_service_role_key IS NULL THEN
    UPDATE public.pickup_game_update_events
    SET push_delivery_status = 'retryable',
        push_last_error = 'vault_secrets_missing',
        push_attempt_count = push_attempt_count + 1,
        push_attempted_at = now()
    WHERE id = p_update_event_id
      AND push_sent_at IS NULL
      AND push_delivery_status IS DISTINCT FROM 'sent'
      AND push_delivery_status IS DISTINCT FROM 'skipped';
    RETURN;
  END IF;

  v_headers := jsonb_build_object(
    'Content-Type', 'application/json',
    'Authorization', 'Bearer ' || v_service_role_key
  );
  IF v_cron_secret IS NOT NULL THEN
    v_headers := v_headers || jsonb_build_object(
      'x-cron-secret', v_cron_secret,
      'x-fangeo-cron-secret', v_cron_secret
    );
  END IF;

  SELECT net.http_post(
    url := v_url || '/functions/v1/notify-pickup-game-change',
    headers := v_headers,
    body := jsonb_build_object('update_event_id', p_update_event_id),
    timeout_milliseconds := 60000
  ) INTO v_request_id;

  UPDATE public.pickup_game_update_events
  SET push_delivery_status = 'queued',
      push_queued_at = coalesce(push_queued_at, now()),
      push_last_error = NULL
  WHERE id = p_update_event_id
    AND push_sent_at IS NULL
    AND push_delivery_status IS DISTINCT FROM 'sent'
    AND push_delivery_status IS DISTINCT FROM 'skipped';
EXCEPTION
  WHEN OTHERS THEN
    -- Do not rethrow: pickup UPDATE + chat message must remain committed.
    UPDATE public.pickup_game_update_events
    SET push_delivery_status = 'retryable',
        push_last_error = left('queue_invoke_failed: ' || SQLERRM, 500),
        push_attempt_count = push_attempt_count + 1,
        push_attempted_at = now()
    WHERE id = p_update_event_id
      AND push_sent_at IS NULL
      AND push_delivery_status IS DISTINCT FROM 'sent'
      AND push_delivery_status IS DISTINCT FROM 'skipped';
END;
$$;

-- ---------------------------------------------------------------------------
-- Recipient token list (service_role / Edge only)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_pickup_game_change_push_tokens(
  p_pickup_game_id uuid,
  p_exclude_user_id uuid
)
RETURNS TABLE (
  token_id uuid,
  user_id uuid,
  token text,
  environment text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH affected AS (
    SELECT r.requester_user_id AS uid
    FROM public.pickup_game_requests r
    WHERE r.pickup_game_id = p_pickup_game_id
      AND lower(btrim(r.status)) IN ('approved', 'pending')
    UNION
    SELECT i.invitee_user_id AS uid
    FROM public.pickup_game_invites i
    WHERE i.pickup_game_id = p_pickup_game_id
      AND lower(btrim(i.status)) IN ('pending', 'maybe', 'accepted')
  )
  SELECT DISTINCT ON (t.user_id, t.token, t.environment)
    t.id AS token_id,
    t.user_id,
    t.token,
    t.environment
  FROM public.user_push_tokens t
  INNER JOIN affected a ON a.uid = t.user_id
  LEFT JOIN public.user_notification_preferences p ON p.user_id = t.user_id
  LEFT JOIN public.user_profiles up ON up.id = t.user_id
  WHERE t.is_active = true
    AND (p_exclude_user_id IS NULL OR t.user_id IS DISTINCT FROM p_exclude_user_id)
    AND COALESCE(p.pickup_game_change_notifications_enabled, true) = true
    AND up.deleted_at IS NULL
    AND NOT EXISTS (
      SELECT 1
      FROM public.user_bans ub
      WHERE ub.user_id = t.user_id
        AND public.is_user_ban_active(ub.expires_at, ub.lifted_at)
    )
  ORDER BY t.user_id, t.token, t.environment, t.last_seen_at DESC NULLS LAST;
$$;

-- ---------------------------------------------------------------------------
-- Claim / finalize helpers for Edge worker (service_role only)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.claim_pickup_game_change_push_event(
  p_update_event_id uuid
)
RETURNS public.pickup_game_update_events
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row public.pickup_game_update_events;
BEGIN
  UPDATE public.pickup_game_update_events e
  SET push_delivery_status = 'sending',
      push_attempt_count = e.push_attempt_count + 1,
      push_attempted_at = now(),
      push_last_error = NULL
  WHERE e.id = p_update_event_id
    AND e.push_sent_at IS NULL
    AND e.push_delivery_status IN ('pending', 'queued', 'retryable', 'failed')
  RETURNING e.* INTO v_row;

  -- Reclaim stuck "sending" after 10 minutes (crashed worker).
  IF v_row.id IS NULL THEN
    UPDATE public.pickup_game_update_events e
    SET push_delivery_status = 'sending',
        push_attempt_count = e.push_attempt_count + 1,
        push_attempted_at = now(),
        push_last_error = NULL
    WHERE e.id = p_update_event_id
      AND e.push_sent_at IS NULL
      AND e.push_delivery_status = 'sending'
      AND e.push_attempted_at IS NOT NULL
      AND e.push_attempted_at < now() - interval '10 minutes'
    RETURNING e.* INTO v_row;
  END IF;

  RETURN v_row;
END;
$$;

CREATE OR REPLACE FUNCTION public.finalize_pickup_game_change_push_event(
  p_update_event_id uuid,
  p_status text,
  p_error text DEFAULT NULL,
  p_skip_reason text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_status text := lower(btrim(coalesce(p_status, '')));
BEGIN
  IF v_status NOT IN ('sent', 'failed', 'retryable', 'skipped') THEN
    RAISE EXCEPTION 'invalid finalize status' USING ERRCODE = '22023';
  END IF;

  UPDATE public.pickup_game_update_events
  SET push_delivery_status = v_status,
      push_sent_at = CASE WHEN v_status = 'sent' THEN coalesce(push_sent_at, now()) ELSE push_sent_at END,
      push_last_error = CASE
        WHEN v_status IN ('failed', 'retryable') THEN left(nullif(btrim(p_error), ''), 500)
        ELSE NULL
      END,
      push_skip_reason = CASE
        WHEN v_status = 'skipped' THEN left(nullif(btrim(coalesce(p_skip_reason, p_error)), ''), 200)
        ELSE push_skip_reason
      END
  WHERE id = p_update_event_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_pickup_game_change_push_delivery(
  p_update_event_id uuid,
  p_user_id uuid,
  p_token_id uuid,
  p_status text,
  p_error_reason text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_status text := lower(btrim(coalesce(p_status, '')));
BEGIN
  IF v_status NOT IN ('sent', 'failed', 'skipped') THEN
    RAISE EXCEPTION 'invalid delivery status' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.pickup_game_update_push_deliveries (
    update_event_id, user_id, token_id, status, error_reason
  )
  VALUES (
    p_update_event_id,
    p_user_id,
    p_token_id,
    v_status,
    left(nullif(btrim(p_error_reason), ''), 300)
  )
  ON CONFLICT (update_event_id, user_id) DO UPDATE
  SET
    token_id = COALESCE(EXCLUDED.token_id, public.pickup_game_update_push_deliveries.token_id),
    status = CASE
      WHEN public.pickup_game_update_push_deliveries.status = 'sent' THEN 'sent'
      ELSE EXCLUDED.status
    END,
    error_reason = CASE
      WHEN public.pickup_game_update_push_deliveries.status = 'sent' THEN NULL
      ELSE EXCLUDED.error_reason
    END
  WHERE public.pickup_game_update_push_deliveries.status IS DISTINCT FROM 'sent'
     OR EXCLUDED.status = 'sent';

  -- True when this user is already (or newly) marked sent for the event.
  RETURN EXISTS (
    SELECT 1
    FROM public.pickup_game_update_push_deliveries d
    WHERE d.update_event_id = p_update_event_id
      AND d.user_id = p_user_id
      AND d.status = 'sent'
  );
END;
$$;

-- True when this user already received a successful push for the event.
CREATE OR REPLACE FUNCTION public.pickup_game_change_push_already_sent(
  p_update_event_id uuid,
  p_user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.pickup_game_update_push_deliveries d
    WHERE d.update_event_id = p_update_event_id
      AND d.user_id = p_user_id
      AND d.status = 'sent'
  );
$$;

-- Optional ops/cron retry for durable retryable/failed/pending events.
CREATE OR REPLACE FUNCTION public.retry_pickup_game_change_push_notifications(
  p_limit integer DEFAULT 25
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id uuid;
  v_count integer := 0;
BEGIN
  FOR v_id IN
    SELECT e.id
    FROM public.pickup_game_update_events e
    WHERE e.push_sent_at IS NULL
      AND e.push_delivery_status IN ('pending', 'queued', 'retryable', 'failed')
      AND e.push_attempt_count < 8
    ORDER BY e.created_at ASC
    LIMIT greatest(1, least(coalesce(p_limit, 25), 100))
  LOOP
    PERFORM public.queue_pickup_game_change_push_notification(v_id);
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END;
$$;

-- ---------------------------------------------------------------------------
-- Core notify (TRIGGER-ONLY). Fabricated direct calls are rejected.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notify_pickup_game_updated_from_rows(
  p_old public.pickup_games,
  p_new public.pickup_games,
  p_editor uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_kinds text[];
  v_fingerprint text;
  v_event_id uuid;
  v_existing public.pickup_game_update_events%ROWTYPE;
  v_conversation_id uuid;
  v_message_id uuid;
  v_is_cancel boolean;
  v_body text := 'Pickup game updated';
  v_payload jsonb;
  v_technical_sender uuid;
BEGIN
  -- Prevent direct client/service SQL invocation with fabricated OLD/NEW rows.
  IF pg_trigger_depth() IS NULL OR pg_trigger_depth() < 1 THEN
    RAISE EXCEPTION 'notify_pickup_game_updated_from_rows is trigger-only'
      USING ERRCODE = '42501';
  END IF;

  IF p_new.id IS NULL OR p_old.id IS DISTINCT FROM p_new.id THEN
    RETURN NULL;
  END IF;

  v_kinds := public.pickup_meaningful_change_kinds(p_old, p_new);
  IF coalesce(array_length(v_kinds, 1), 0) = 0 THEN
    RETURN NULL;
  END IF;

  -- Editor identity for exclusion/audit is p_editor (nullable). Never impersonate organizer.
  -- group_messages.sender_id is NOT NULL, so system rows use editor when known, else creator
  -- as a technical FK only. Payload.actor_user_id / editor_is_system remain authoritative.
  v_technical_sender := coalesce(p_editor, p_new.creator_user_id);

  v_fingerprint := md5(
    p_new.id::text || '|' ||
    array_to_string(v_kinds, ',') || '|' ||
    coalesce(p_new.updated_at::text, '') || '|' ||
    public.pickup_location_identity(
      p_new.address, p_new.city, p_new.state, p_new.latitude, p_new.longitude
    ) || '|' ||
    coalesce(p_new.game_start_at::text, '') || '|' ||
    coalesce(p_new.end_time::text, '') || '|' ||
    coalesce(p_new.status, '') || '|' ||
    coalesce(p_new.players_needed::text, '') || '|' ||
    coalesce(p_new.max_players::text, '') || '|' ||
    public.pickup_norm_text(p_new.title) || '|' ||
    public.pickup_norm_text(p_new.sport) || '|' ||
    public.pickup_norm_text(p_new.skill_level) || '|' ||
    public.pickup_norm_text(p_new.play_environment) || '|' ||
    public.pickup_norm_text(p_new.participant_preference) || '|' ||
    coalesce(p_new.is_free::text, '') || '|' ||
    coalesce(p_new.entry_fee_amount::text, '') || '|' ||
    coalesce(p_new.is_visible::text, '')
  );

  INSERT INTO public.pickup_game_update_events AS e (
    pickup_game_id, editor_user_id, fingerprint, change_kinds, payload, push_delivery_status
  )
  VALUES (
    p_new.id,
    p_editor, -- may be NULL
    v_fingerprint,
    v_kinds,
    jsonb_build_object(
      'title', p_new.title,
      'before_start', p_old.game_start_at,
      'after_start', p_new.game_start_at,
      'before_location', public.pickup_location_label(p_old.address, p_old.city, p_old.state),
      'after_location', public.pickup_location_label(p_new.address, p_new.city, p_new.state),
      'before_players_needed', p_old.players_needed,
      'after_players_needed', p_new.players_needed,
      'before_status', p_old.status,
      'after_status', p_new.status
    ),
    'pending'
  )
  ON CONFLICT (pickup_game_id, fingerprint) DO NOTHING
  RETURNING id INTO v_event_id;

  IF v_event_id IS NULL THEN
    SELECT * INTO v_existing
    FROM public.pickup_game_update_events
    WHERE pickup_game_id = p_new.id AND fingerprint = v_fingerprint;

    IF v_existing.id IS NULL THEN
      RETURN NULL;
    END IF;

    -- Idempotent retry of the same logical edit: never duplicate chat; re-queue push if needed.
    IF v_existing.push_sent_at IS NULL
       AND v_existing.push_delivery_status IN ('pending', 'queued', 'retryable', 'failed') THEN
      PERFORM public.queue_pickup_game_change_push_notification(v_existing.id);
    END IF;
    RETURN v_existing.id;
  END IF;

  v_is_cancel := lower(coalesce(p_old.status, '')) <> 'removed'
             AND lower(coalesce(p_new.status, '')) = 'removed';

  -- Locale-neutral stored body/preview. iOS rebuilds localized copy from structured payload.
  v_body := 'Pickup game updated';

  v_payload := jsonb_build_object(
    'event', 'pickup_game_updated',
    'pickup_game_id', p_new.id,
    'update_event_id', v_event_id,
    'change_kinds', to_jsonb(v_kinds),
    'summary_lines', jsonb_build_array(v_body),
    'actor_user_id', to_jsonb(p_editor),
    'editor_is_system', (p_editor IS NULL),
    'before_start', p_old.game_start_at,
    'after_start', p_new.game_start_at,
    'before_location', public.pickup_location_label(p_old.address, p_old.city, p_old.state),
    'after_location', public.pickup_location_label(p_new.address, p_new.city, p_new.state),
    'before_players_needed', p_old.players_needed,
    'after_players_needed', p_new.players_needed,
    'before_status', p_old.status,
    'after_status', p_new.status,
    'title', p_new.title,
    'is_cancellation', v_is_cancel
  );

  SELECT c.id INTO v_conversation_id
  FROM public.group_conversations c
  WHERE c.pickup_game_id = p_new.id
  LIMIT 1;

  IF v_conversation_id IS NOT NULL AND v_technical_sender IS NOT NULL THEN
    INSERT INTO public.group_messages (
      conversation_id, sender_id, body, message_type, system_event, system_payload
    )
    VALUES (
      v_conversation_id,
      v_technical_sender,
      v_body,
      'system',
      'pickup_game_updated',
      v_payload
    )
    RETURNING id INTO v_message_id;

    UPDATE public.pickup_game_update_events
    SET chat_message_id = v_message_id,
        payload = payload || jsonb_build_object('chat_message_id', v_message_id) || v_payload
    WHERE id = v_event_id;

    UPDATE public.group_conversations
    SET last_message_at = now(),
        last_message_preview = left(v_body, 180),
        last_message_sender_id = v_technical_sender,
        last_message_type = 'system',
        last_system_event = 'pickup_game_updated'
    WHERE id = v_conversation_id;
  ELSE
    UPDATE public.pickup_game_update_events
    SET payload = payload || v_payload
    WHERE id = v_event_id;
  END IF;

  PERFORM public.queue_pickup_game_change_push_notification(v_event_id);
  RETURN v_event_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.trg_pickup_games_notify_meaningful_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Pass auth.uid() as-is (NULL for service-role). Do not substitute creator.
  PERFORM public.notify_pickup_game_updated_from_rows(OLD, NEW, auth.uid());
  RETURN NEW;
EXCEPTION
  WHEN OTHERS THEN
    -- Notification path must not fail the organizer's UPDATE.
    RAISE WARNING 'pickup edit notify failed: %', SQLERRM;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_pickup_games_notify_meaningful_update
  ON public.pickup_games;
CREATE TRIGGER trg_pickup_games_notify_meaningful_update
  AFTER UPDATE ON public.pickup_games
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_pickup_games_notify_meaningful_update();

-- Drop obsolete no-op client RPC from earlier draft (if present).
DROP FUNCTION IF EXISTS public.notify_pickup_game_updated_if_needed(uuid);

-- ---------------------------------------------------------------------------
-- Privilege lockdown (do not rely on PostgreSQL defaults)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'pickup_norm_text',
        'pickup_round_coord',
        'pickup_location_place_text',
        'pickup_location_identity',
        'pickup_location_label',
        'pickup_meaningful_change_kinds',
        'queue_pickup_game_change_push_notification',
        'list_pickup_game_change_push_tokens',
        'claim_pickup_game_change_push_event',
        'finalize_pickup_game_change_push_event',
        'record_pickup_game_change_push_delivery',
        'pickup_game_change_push_already_sent',
        'retry_pickup_game_change_push_notifications',
        'notify_pickup_game_updated_from_rows',
        'trg_pickup_games_notify_meaningful_update'
      )
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', r.sig);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon', r.sig);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM authenticated', r.sig);
  END LOOP;
END $$;

-- Service-role Edge / ops only.
GRANT EXECUTE ON FUNCTION public.queue_pickup_game_change_push_notification(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.list_pickup_game_change_push_tokens(uuid, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.claim_pickup_game_change_push_event(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.finalize_pickup_game_change_push_event(uuid, text, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.record_pickup_game_change_push_delivery(uuid, uuid, uuid, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.pickup_game_change_push_already_sent(uuid, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.retry_pickup_game_change_push_notifications(integer) TO service_role;

-- Trigger + internal helpers: no client/service direct EXECUTE grants.
-- (Owner + trigger machinery can still invoke them.)

COMMENT ON FUNCTION public.notify_pickup_game_updated_from_rows(public.pickup_games, public.pickup_games, uuid) IS
  'TRIGGER-ONLY. Creates one deduped update event + optional chat system message + queues push. Rejects direct invocation (pg_trigger_depth).';

COMMENT ON FUNCTION public.queue_pickup_game_change_push_notification(uuid) IS
  'Best-effort pg_net invoke of notify-pickup-game-change. Marks retryable on failure; never raises to callers.';

COMMENT ON FUNCTION public.list_pickup_game_change_push_tokens(uuid, uuid) IS
  'Service-role token list for pickup edit pushes. Approved/pending joiners + pending/maybe/accepted invitees; preference + ban + deleted gates; excludes editor when provided.';

COMMIT;
