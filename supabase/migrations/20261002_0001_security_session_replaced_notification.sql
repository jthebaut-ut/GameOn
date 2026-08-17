-- =============================================================================
-- 20261002_0001 — Security notification when a single-active session is replaced
-- =============================================================================
-- Hooks the existing fan/business session claim (`user_profiles.active_session_id`)
-- so the SERVER can APNs the OLD device at takeover time.
--
-- Additive / non-destructive. Do NOT apply from the agent. Treat linked
-- Supabase as production — apply manually after review.
--
-- Sequence:
--   1) New login calls claim_active_session (installation_id + session id)
--   2) RPC locks the profile, captures OLD APNs tokens (excluding new install)
--   3) Writes durable Inbox SECURITY row
--   4) Queues notify-session-replaced via pg_net
--   5) Commits the new active_session_id
--   6) APNs failure never blocks the claim
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Session identity columns (installation distinguishes same vs other device)
-- ---------------------------------------------------------------------------
ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS active_installation_id uuid,
  ADD COLUMN IF NOT EXISTS active_device_family text;

COMMENT ON COLUMN public.user_profiles.active_installation_id IS
  'Stable per-app-install id of the device that currently holds active_session_id. '
  'Used to avoid false “another device” warnings on same-device re-auth.';

COMMENT ON COLUMN public.user_profiles.active_device_family IS
  'Coarse device family last claimed (iPhone / iPad). Never an IP, UA, or fingerprint.';

-- ---------------------------------------------------------------------------
-- 2) Durable replacement event + captured old-device tokens
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.security_session_replaced_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  old_session_id text,
  new_session_id text NOT NULL,
  old_installation_id uuid,
  new_installation_id uuid,
  new_device_family text,
  account_kind text NOT NULL DEFAULT 'fan'
    CHECK (account_kind IN ('fan', 'business')),
  dedupe_key text NOT NULL,
  captured_tokens jsonb NOT NULL DEFAULT '[]'::jsonb,
  inbox_row_id uuid,
  notify_decision text NOT NULL DEFAULT 'pending',
  apns_attempted boolean NOT NULL DEFAULT false,
  apns_status text,
  apns_reason text,
  old_token_count integer NOT NULL DEFAULT 0,
  sent_token_count integer NOT NULL DEFAULT 0,
  pg_net_request_id bigint,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT security_session_replaced_events_user_dedupe_uidx
    UNIQUE (user_id, dedupe_key),
  CONSTRAINT security_session_replaced_events_dedupe_len_ck
    CHECK (char_length(dedupe_key) BETWEEN 1 AND 180)
);

CREATE INDEX IF NOT EXISTS security_session_replaced_events_user_created_idx
  ON public.security_session_replaced_events (user_id, created_at DESC);

COMMENT ON TABLE public.security_session_replaced_events IS
  'Idempotent ledger for single-session takeover security pushes. Captures old-device '
  'APNs tokens before the new session is committed. No access/refresh tokens stored.';

ALTER TABLE public.security_session_replaced_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.security_session_replaced_events FROM PUBLIC;
REVOKE ALL ON TABLE public.security_session_replaced_events FROM anon;
REVOKE ALL ON TABLE public.security_session_replaced_events FROM authenticated;
GRANT ALL ON TABLE public.security_session_replaced_events TO service_role;

-- ---------------------------------------------------------------------------
-- 3) Inbox kind/destination: dedicated security row (not Team/chat/pro-game)
-- ---------------------------------------------------------------------------
ALTER TABLE public.fan_notification_inbox
  DROP CONSTRAINT IF EXISTS fan_notification_inbox_kind_ck;

ALTER TABLE public.fan_notification_inbox
  ADD CONSTRAINT fan_notification_inbox_kind_ck CHECK (
    kind_raw IN ('scheduleChange', 'eventCancellation', 'poke', 'securitySession')
  );

CREATE OR REPLACE FUNCTION public.upsert_fan_notification_inbox(
  p_user_id uuid,
  p_notification_type text,
  p_title text,
  p_body text,
  p_kind_raw text,
  p_destination_raw text,
  p_deduplication_key text,
  p_source_type text DEFAULT NULL,
  p_source_id text DEFAULT NULL,
  p_team_id uuid DEFAULT NULL,
  p_event_id uuid DEFAULT NULL,
  p_actor_user_id uuid DEFAULT NULL,
  p_payload jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_id uuid;
  v_key text;
  v_title text;
  v_body text;
  v_kind text;
  v_dest text;
  v_type text;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_key := lower(btrim(coalesce(p_deduplication_key, '')));
  v_key := regexp_replace(v_key, '[^a-z0-9_\-:\.]', '', 'g');
  IF v_key = '' THEN
    RETURN NULL;
  END IF;
  IF char_length(v_key) > 180 THEN
    v_key := left(v_key, 180);
  END IF;

  v_title := nullif(btrim(coalesce(p_title, '')), '');
  IF v_title IS NULL THEN
    RETURN NULL;
  END IF;
  v_body := coalesce(btrim(p_body), '');
  v_type := lower(btrim(coalesce(p_notification_type, 'schedule_change')));
  IF v_type = '' THEN
    v_type := 'schedule_change';
  END IF;
  v_kind := CASE lower(btrim(coalesce(p_kind_raw, '')))
    WHEN 'eventcancellation' THEN 'eventCancellation'
    WHEN 'event_cancellation' THEN 'eventCancellation'
    WHEN 'poke' THEN 'poke'
    WHEN 'securitysession' THEN 'securitySession'
    WHEN 'security_session' THEN 'securitySession'
    ELSE 'scheduleChange'
  END;
  v_dest := CASE lower(btrim(coalesce(p_destination_raw, '')))
    WHEN 'teamshome' THEN 'teamsHome'
    WHEN 'teams_home' THEN 'teamsHome'
    WHEN 'my_teams' THEN 'teamsHome'
    WHEN 'teamsinvites' THEN 'teamsInvites'
    WHEN 'teams_invites' THEN 'teamsInvites'
    WHEN 'accountpokes' THEN 'accountPokes'
    WHEN 'account_pokes' THEN 'accountPokes'
    WHEN 'chatfriendrequests' THEN 'chatFriendRequests'
    WHEN 'chat_friend_requests' THEN 'chatFriendRequests'
    WHEN 'chatunread' THEN 'chatUnread'
    WHEN 'goingpickupinvites' THEN 'goingPickupInvites'
    WHEN 'goinghostingapprovals' THEN 'goingHostingApprovals'
    WHEN 'goingpendingrating' THEN 'goingPendingRating'
    WHEN 'accountbusinessclaim' THEN 'accountBusinessClaim'
    WHEN 'accountsecurity' THEN 'accountSecurity'
    WHEN 'account_security' THEN 'accountSecurity'
    WHEN 'scheduleactivity' THEN 'scheduleActivity'
    WHEN 'schedule_activity' THEN 'scheduleActivity'
    ELSE 'scheduleActivity'
  END;

  INSERT INTO public.fan_notification_inbox AS i (
    user_id,
    notification_type,
    title,
    body,
    kind_raw,
    destination_raw,
    source_type,
    source_id,
    team_id,
    event_id,
    actor_user_id,
    payload,
    deduplication_key
  ) VALUES (
    p_user_id,
    v_type,
    left(v_title, 240),
    left(v_body, 500),
    v_kind,
    v_dest,
    nullif(btrim(coalesce(p_source_type, '')), ''),
    nullif(btrim(coalesce(p_source_id, '')), ''),
    p_team_id,
    p_event_id,
    p_actor_user_id,
    coalesce(p_payload, '{}'::jsonb),
    v_key
  )
  ON CONFLICT (user_id, deduplication_key) DO UPDATE
    SET
      title = EXCLUDED.title,
      body = EXCLUDED.body,
      notification_type = EXCLUDED.notification_type,
      kind_raw = EXCLUDED.kind_raw,
      destination_raw = EXCLUDED.destination_raw,
      source_type = EXCLUDED.source_type,
      source_id = EXCLUDED.source_id,
      team_id = COALESCE(EXCLUDED.team_id, i.team_id),
      event_id = COALESCE(EXCLUDED.event_id, i.event_id),
      actor_user_id = COALESCE(EXCLUDED.actor_user_id, i.actor_user_id),
      payload = EXCLUDED.payload
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_fan_notification_inbox(
  uuid, text, text, text, text, text, text, text, text, uuid, uuid, uuid, jsonb
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.upsert_fan_notification_inbox(
  uuid, text, text, text, text, text, text, text, text, uuid, uuid, uuid, jsonb
) FROM anon;
REVOKE ALL ON FUNCTION public.upsert_fan_notification_inbox(
  uuid, text, text, text, text, text, text, text, text, uuid, uuid, uuid, jsonb
) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_fan_notification_inbox(
  uuid, text, text, text, text, text, text, text, text, uuid, uuid, uuid, jsonb
) TO service_role;

-- ---------------------------------------------------------------------------
-- 4) Pure decision helper (testable; no side effects)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.security_session_replacement_should_notify(
  p_old_session_id text,
  p_new_session_id text,
  p_old_installation_id uuid,
  p_new_installation_id uuid
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN nullif(btrim(coalesce(p_new_session_id, '')), '') IS NULL THEN 'missing_new_session'
    WHEN p_new_installation_id IS NULL THEN 'missing_new_installation'
    WHEN nullif(btrim(coalesce(p_old_session_id, '')), '') IS NULL
         AND p_old_installation_id IS NULL THEN 'no_previous_session'
    WHEN p_old_installation_id IS NOT NULL
         AND p_old_installation_id = p_new_installation_id THEN 'same_device'
    WHEN nullif(btrim(coalesce(p_old_session_id, '')), '') IS NOT NULL
         AND lower(btrim(p_old_session_id)) = lower(btrim(p_new_session_id))
         AND (
           p_old_installation_id IS NULL
           OR p_old_installation_id = p_new_installation_id
         ) THEN 'same_claim'
    ELSE 'notify'
  END;
$$;

COMMENT ON FUNCTION public.security_session_replacement_should_notify(text, text, uuid, uuid) IS
  'Same-device / first-claim / missing-identity guard for session-replacement security pushes.';

REVOKE ALL ON FUNCTION public.security_session_replacement_should_notify(text, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.security_session_replacement_should_notify(text, text, uuid, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.security_session_replaced_dedupe_key(
  p_old_installation_id uuid,
  p_old_session_id text,
  p_new_session_id text
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT left(
    'security_session_replaced:'
      || coalesce(p_old_installation_id::text, lower(btrim(coalesce(p_old_session_id, 'none'))))
      || ':'
      || lower(btrim(coalesce(p_new_session_id, 'none'))),
    180
  );
$$;

REVOKE ALL ON FUNCTION public.security_session_replaced_dedupe_key(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.security_session_replaced_dedupe_key(uuid, text, text)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5) Queue APNs worker (best-effort; never raises to caller)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.queue_security_session_replaced_notification(
  p_event_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_url text;
  v_service_role_key text;
  v_cron_secret text;
  v_headers jsonb;
  v_request_id bigint;
BEGIN
  IF p_event_id IS NULL THEN
    RETURN;
  END IF;

  IF to_regnamespace('net') IS NULL OR to_regclass('vault.decrypted_secrets') IS NULL THEN
    UPDATE public.security_session_replaced_events
    SET
      apns_attempted = false,
      apns_status = 'skipped',
      apns_reason = 'pg_net_or_vault_unavailable',
      updated_at = now()
    WHERE id = p_event_id
      AND apns_status IS DISTINCT FROM 'sent';
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

  IF v_url IS NULL OR v_service_role_key IS NULL THEN
    UPDATE public.security_session_replaced_events
    SET
      apns_attempted = false,
      apns_status = 'skipped',
      apns_reason = 'vault_secrets_missing',
      updated_at = now()
    WHERE id = p_event_id
      AND apns_status IS DISTINCT FROM 'sent';
    RETURN;
  END IF;

  SELECT decrypted_secret
  INTO v_cron_secret
  FROM vault.decrypted_secrets
  WHERE name IN ('SESSION_REPLACED_PUSH_CRON_SECRET', 'POKE_PUSH_CRON_SECRET')
    AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
  ORDER BY CASE name WHEN 'SESSION_REPLACED_PUSH_CRON_SECRET' THEN 0 ELSE 1 END
  LIMIT 1;

  v_headers := jsonb_build_object(
    'Content-Type', 'application/json',
    'Authorization', 'Bearer ' || v_service_role_key,
    'apikey', v_service_role_key
  );
  IF v_cron_secret IS NOT NULL THEN
    v_headers := v_headers || jsonb_build_object(
      'x-cron-secret', v_cron_secret,
      'x-fangeo-cron-secret', v_cron_secret
    );
  END IF;

  SELECT net.http_post(
    url := v_url || '/functions/v1/notify-session-replaced',
    headers := v_headers,
    body := jsonb_build_object('event_id', p_event_id),
    timeout_milliseconds := 60000
  ) INTO v_request_id;

  UPDATE public.security_session_replaced_events
  SET
    apns_attempted = true,
    apns_status = 'queued',
    apns_reason = NULL,
    pg_net_request_id = v_request_id,
    updated_at = now()
  WHERE id = p_event_id
    AND apns_status IS DISTINCT FROM 'sent';
EXCEPTION
  WHEN OTHERS THEN
    UPDATE public.security_session_replaced_events
    SET
      apns_attempted = true,
      apns_status = 'failed',
      apns_reason = left('queue_invoke_failed: ' || SQLERRM, 180),
      updated_at = now()
    WHERE id = p_event_id
      AND apns_status IS DISTINCT FROM 'sent';
END;
$$;

REVOKE ALL ON FUNCTION public.queue_security_session_replaced_notification(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.queue_security_session_replaced_notification(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.queue_security_session_replaced_notification(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.queue_security_session_replaced_notification(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 6) Shared notify helper (fan + business). Never raises.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notify_replaced_session_device(
  p_user_id uuid,
  p_old_session_id text,
  p_new_session_id text,
  p_old_installation_id uuid,
  p_new_installation_id uuid,
  p_new_device_family text DEFAULT NULL,
  p_account_kind text DEFAULT 'fan'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_decision text;
  v_dedupe text;
  v_event_id uuid;
  v_inbox_id uuid;
  v_tokens jsonb := '[]'::jsonb;
  v_token_count integer := 0;
  v_family text;
  v_kind text;
  v_inserted boolean := false;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'decision', 'missing_user');
  END IF;

  v_kind := CASE lower(btrim(coalesce(p_account_kind, 'fan')))
    WHEN 'business' THEN 'business'
    ELSE 'fan'
  END;
  v_family := nullif(btrim(coalesce(p_new_device_family, '')), '');
  IF v_family IS NOT NULL THEN
    v_family := CASE lower(v_family)
      WHEN 'ipad' THEN 'iPad'
      WHEN 'iphone' THEN 'iPhone'
      WHEN 'ipod' THEN 'iPhone'
      ELSE NULL
    END;
  END IF;

  v_decision := public.security_session_replacement_should_notify(
    p_old_session_id,
    p_new_session_id,
    p_old_installation_id,
    p_new_installation_id
  );
  IF v_decision IS DISTINCT FROM 'notify' THEN
    RETURN jsonb_build_object('ok', true, 'decision', v_decision, 'notified', false);
  END IF;

  v_dedupe := public.security_session_replaced_dedupe_key(
    p_old_installation_id,
    p_old_session_id,
    p_new_session_id
  );

  INSERT INTO public.security_session_replaced_events (
    user_id,
    old_session_id,
    new_session_id,
    old_installation_id,
    new_installation_id,
    new_device_family,
    account_kind,
    dedupe_key,
    notify_decision
  ) VALUES (
    p_user_id,
    nullif(btrim(coalesce(p_old_session_id, '')), ''),
    lower(btrim(p_new_session_id)),
    p_old_installation_id,
    p_new_installation_id,
    v_family,
    v_kind,
    v_dedupe,
    'notify'
  )
  ON CONFLICT (user_id, dedupe_key) DO NOTHING
  RETURNING id INTO v_event_id;

  IF v_event_id IS NULL THEN
    SELECT id, inbox_row_id
    INTO v_event_id, v_inbox_id
    FROM public.security_session_replaced_events
    WHERE user_id = p_user_id
      AND dedupe_key = v_dedupe
    LIMIT 1;
    RETURN jsonb_build_object(
      'ok', true,
      'decision', 'deduped',
      'notified', false,
      'event_id', v_event_id,
      'inbox_row_id', v_inbox_id
    );
  END IF;
  v_inserted := true;

  -- Capture OLD tokens BEFORE any later logout deactivates them.
  -- Never include the new installation. Never store session/access/refresh tokens.
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'id', t.id,
           'token', t.token,
           'environment', t.environment,
           'installation_id', t.installation_id
         ) ORDER BY t.last_seen_at DESC NULLS LAST), '[]'::jsonb),
         count(*)::integer
  INTO v_tokens, v_token_count
  FROM public.user_push_tokens t
  WHERE t.user_id = p_user_id
    AND t.is_active = true
    AND t.installation_id IS DISTINCT FROM p_new_installation_id;

  v_inbox_id := public.upsert_fan_notification_inbox(
    p_user_id,
    'security_session_replaced',
    'New sign-in detected',
    'Your FanGeo account was signed in on another device. This device has been signed out.',
    'securitySession',
    'accountSecurity',
    v_dedupe,
    'security_session_replaced',
    v_event_id::text,
    NULL,
    v_event_id,
    NULL,
    jsonb_strip_nulls(jsonb_build_object(
      'security_event', 'new_sign_in',
      'new_device_type', v_family,
      'account_kind', v_kind,
      'event_id', v_event_id
    ))
  );

  UPDATE public.security_session_replaced_events
  SET
    captured_tokens = v_tokens,
    old_token_count = v_token_count,
    inbox_row_id = v_inbox_id,
    updated_at = now()
  WHERE id = v_event_id;

  IF v_token_count > 0 THEN
    PERFORM public.queue_security_session_replaced_notification(v_event_id);
  ELSE
    UPDATE public.security_session_replaced_events
    SET
      apns_attempted = false,
      apns_status = 'skipped',
      apns_reason = 'no_old_tokens',
      updated_at = now()
    WHERE id = v_event_id;
  END IF;

  RAISE LOG '[SecuritySessionReplaced] user=% event=% old_install=% new_install=% tokens=% inbox=% decision=notify',
    p_user_id, v_event_id, p_old_installation_id, p_new_installation_id, v_token_count, v_inbox_id;

  RETURN jsonb_build_object(
    'ok', true,
    'decision', 'notify',
    'notified', v_token_count > 0,
    'event_id', v_event_id,
    'inbox_row_id', v_inbox_id,
    'old_token_count', v_token_count,
    'inserted', v_inserted
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE LOG '[SecuritySessionReplaced] notify_failed user=% sqlerrm=%', p_user_id, SQLERRM;
    RETURN jsonb_build_object(
      'ok', true,
      'decision', 'notify_failed',
      'notified', false,
      'reason', left(SQLERRM, 120)
    );
END;
$$;

COMMENT ON FUNCTION public.notify_replaced_session_device(uuid, text, text, uuid, uuid, text, text) IS
  'Shared fan/business helper: capture old-device APNs tokens, write Inbox SECURITY row, '
  'queue APNs. Best-effort; never fails session claim. No secrets in payload.';

REVOKE ALL ON FUNCTION public.notify_replaced_session_device(uuid, text, text, uuid, uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.notify_replaced_session_device(uuid, text, text, uuid, uuid, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.notify_replaced_session_device(uuid, text, text, uuid, uuid, text, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.notify_replaced_session_device(uuid, text, text, uuid, uuid, text, text) TO service_role;
-- Nested call from claim_active_session (SECURITY DEFINER, same owner) does not need
-- authenticated EXECUTE. Do not grant this to authenticated: it would let a client
-- fire a fake “another device” push without actually claiming the session.

-- ---------------------------------------------------------------------------
-- 7) Authoritative claim RPC — replaces client UPDATE of active_session_id
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.claim_active_session(
  p_session_id text,
  p_installation_id uuid,
  p_device_family text DEFAULT NULL,
  p_account_kind text DEFAULT 'fan'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_session text;
  v_old_session text;
  v_old_install uuid;
  v_notify jsonb;
  v_kind text;
  v_family text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '42501';
  END IF;

  v_session := lower(btrim(coalesce(p_session_id, '')));
  IF v_session = '' THEN
    RAISE EXCEPTION 'invalid_session' USING ERRCODE = '22023';
  END IF;
  IF p_installation_id IS NULL THEN
    RAISE EXCEPTION 'invalid_installation' USING ERRCODE = '22023';
  END IF;

  v_kind := CASE lower(btrim(coalesce(p_account_kind, 'fan')))
    WHEN 'business' THEN 'business'
    ELSE 'fan'
  END;
  v_family := nullif(btrim(coalesce(p_device_family, '')), '');

  -- Row lock serializes concurrent claims for the same account.
  SELECT active_session_id, active_installation_id
  INTO v_old_session, v_old_install
  FROM public.user_profiles
  WHERE id = v_uid
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_profile', 'claimed', false);
  END IF;

  -- Capture old identity, then commit the new session. Notify uses the snapshot.
  v_notify := public.notify_replaced_session_device(
    v_uid,
    v_old_session,
    v_session,
    v_old_install,
    p_installation_id,
    v_family,
    v_kind
  );

  UPDATE public.user_profiles
  SET
    active_session_id = v_session,
    active_session_updated_at = now(),
    active_installation_id = p_installation_id,
    active_device_family = CASE lower(btrim(coalesce(v_family, '')))
      WHEN 'ipad' THEN 'iPad'
      WHEN 'iphone' THEN 'iPhone'
      WHEN 'ipod' THEN 'iPhone'
      ELSE active_device_family
    END
  WHERE id = v_uid;

  RETURN jsonb_build_object(
    'ok', true,
    'claimed', true,
    'old_session_found', v_old_session IS NOT NULL,
    'old_installation_found', v_old_install IS NOT NULL,
    'new_installation_id', p_installation_id,
    'notify', coalesce(v_notify, '{}'::jsonb)
  );
EXCEPTION
  WHEN SQLSTATE '42501' THEN
    RAISE;
  WHEN SQLSTATE '22023' THEN
    RAISE;
  WHEN OTHERS THEN
    -- Last-resort: still try to claim so login is never blocked by notify/lock issues.
    BEGIN
      UPDATE public.user_profiles
      SET
        active_session_id = lower(btrim(coalesce(p_session_id, ''))),
        active_session_updated_at = now(),
        active_installation_id = coalesce(p_installation_id, active_installation_id)
      WHERE id = auth.uid()
        AND lower(btrim(coalesce(p_session_id, ''))) <> '';
    EXCEPTION
      WHEN OTHERS THEN
        NULL;
    END;
    RETURN jsonb_build_object(
      'ok', true,
      'claimed', true,
      'reason', 'claim_with_notify_error',
      'notify_error', left(SQLERRM, 120)
    );
END;
$$;

COMMENT ON FUNCTION public.claim_active_session(text, uuid, text, text) IS
  'Single-active-session claim for auth.uid() (fan or business). Captures old-device '
  'APNs tokens and queues a security push before the new session becomes authoritative. '
  'Same-device re-auth does not notify. APNs failure never fails the claim.';

REVOKE ALL ON FUNCTION public.claim_active_session(text, uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.claim_active_session(text, uuid, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.claim_active_session(text, uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.claim_active_session(text, uuid, text, text) TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
