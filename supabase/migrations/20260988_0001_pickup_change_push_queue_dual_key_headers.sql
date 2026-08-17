-- =============================================================================
-- 20260988_0001 — Dual-key headers for pickup/Team change APNs queue
-- =============================================================================
-- Inbox fan-out already succeeds inside queue_pickup_game_change_push_notification
-- BEFORE pg_net. APNs failed because notify-pickup-game-change compared the
-- Vault Bearer (typically fangeo_service_role_key JWT) only against hosted
-- SERVICE_ROLE_KEY (often sb_secret_* after the dual-key cutover) → 401
-- invalid_secret, so claim/ApnsClient.send never ran.
--
-- This migration does NOT weaken auth. It only sends the same Vault secret
-- on BOTH Authorization: Bearer and apikey so the Edge worker can accept
-- either credential class via authorizeSportsWorkerRequest (same as sibling
-- Team push functions).
--
-- Edge must be redeployed: notify-pickup-game-change
-- PREPARE ONLY — do not apply from the agent unless instructed.
-- =============================================================================

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

  -- Durable inbox first — survives APNs/pg_net/vault failures and dismissed pushes.
  BEGIN
    PERFORM public.fanout_fan_notification_inbox_for_pickup_update_event(p_update_event_id);
  EXCEPTION
    WHEN OTHERS THEN
      RAISE LOG
        '[FanNotificationInbox] pickupFanoutFailed update_event_id=% err=%',
        p_update_event_id, SQLERRM;
  END;

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

  -- Dual-key: same Vault value on Bearer + apikey. Edge accepts JWT and/or
  -- sb_secret_* via authorizeSportsWorkerRequest. Never log the secret.
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

REVOKE ALL ON FUNCTION public.queue_pickup_game_change_push_notification(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.queue_pickup_game_change_push_notification(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.queue_pickup_game_change_push_notification(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.queue_pickup_game_change_push_notification(uuid) TO service_role;

COMMENT ON FUNCTION public.queue_pickup_game_change_push_notification(uuid) IS
  'Durable inbox fan-out first, then pg_net POST to notify-pickup-game-change with dual-key Bearer+apikey from Vault. APNs remains independent of inbox success.';

NOTIFY pgrst, 'reload schema';
