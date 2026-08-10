-- =============================================================================
-- 20260945_0001 — Fan Team deletion push: queue diagnostics + delivery pre-claim
-- =============================================================================
-- Audit (repo):
--   • delete_fan_team snapshots recipient_user_ids BEFORE soft-leave (CORRECT).
--   • Owner excluded; pending invitees not notified; Team mute ignored in Edge.
--   • Gap: queue discarded pg_net request_id; no delivery rows until Edge claim —
--     if Edge never runs / vault missing, production shows ZERO ledger evidence.
--
-- This migration:
--   1) fan_team_deletion_events.pg_net_request_id for invitation→pg_net correlation
--   2) queue pre-inserts fan_team_deleted_push_deliveries (status=queued) per recipient
--   3) stores net.http_post request_id on the deletion event
--
-- Companion Edge (notify-fan-team-deleted) MUST treat status=queued as claimable
-- (same pattern as Team invitation). Deploy Edge with/after this migration.
--
-- Do NOT apply from the agent. Apply manually after 20260944.
-- =============================================================================

BEGIN;

ALTER TABLE public.fan_team_deletion_events
  ADD COLUMN IF NOT EXISTS pg_net_request_id bigint;

COMMENT ON COLUMN public.fan_team_deletion_events.pg_net_request_id IS
  'net.http_post request id for notify-fan-team-deleted; join net._http_response.id (~6h).';

CREATE OR REPLACE FUNCTION public.queue_fan_team_deleted_push_notification(
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
  v_team_id uuid;
  v_recipients uuid[];
  v_uid uuid;
  v_request_id bigint;
BEGIN
  IF p_event_id IS NULL THEN
    RETURN;
  END IF;

  SELECT e.team_id, coalesce(e.recipient_user_ids, '{}'::uuid[])
  INTO v_team_id, v_recipients
  FROM public.fan_team_deletion_events e
  WHERE e.id = p_event_id;

  IF v_team_id IS NULL THEN
    RAISE NOTICE 'fan team deleted push skipped: event missing event=%', p_event_id;
    RETURN;
  END IF;

  IF coalesce(cardinality(v_recipients), 0) = 0 THEN
    RAISE NOTICE 'fan team deleted push skipped: no recipients event=%', p_event_id;
    RETURN;
  END IF;

  -- Pre-insert per-recipient ledger so "Edge never ran" is visible as queued.
  FOREACH v_uid IN ARRAY v_recipients LOOP
    IF v_uid IS NULL THEN
      CONTINUE;
    END IF;
    INSERT INTO public.fan_team_deleted_push_deliveries (
      event_id, recipient_user_id, team_id, delivery_status
    ) VALUES (
      p_event_id, v_uid, v_team_id, 'queued'
    )
    ON CONFLICT (event_id, recipient_user_id) DO NOTHING;
  END LOOP;

  IF to_regnamespace('net') IS NULL OR to_regclass('vault.decrypted_secrets') IS NULL THEN
    UPDATE public.fan_team_deleted_push_deliveries
    SET delivery_status = 'skipped',
        skip_reason = 'pg_net_or_vault_unavailable',
        updated_at = now()
    WHERE event_id = p_event_id
      AND delivery_status = 'queued';
    RAISE NOTICE 'fan team deleted push skipped: pg_net or vault unavailable event=%', p_event_id;
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
    UPDATE public.fan_team_deleted_push_deliveries
    SET delivery_status = 'skipped',
        skip_reason = 'vault_secrets_missing',
        updated_at = now()
    WHERE event_id = p_event_id
      AND delivery_status = 'queued';
    RAISE NOTICE 'fan team deleted push skipped: vault secrets missing event=%', p_event_id;
    RETURN;
  END IF;

  SELECT decrypted_secret
  INTO v_cron_secret
  FROM vault.decrypted_secrets
  WHERE name = 'FAN_TEAM_DELETED_PUSH_CRON_SECRET'
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

  SELECT net.http_post(
    url := v_url || '/functions/v1/notify-fan-team-deleted',
    headers := v_headers,
    body := jsonb_build_object('event_id', p_event_id),
    timeout_milliseconds := 15000
  ) INTO v_request_id;

  IF v_request_id IS NOT NULL THEN
    UPDATE public.fan_team_deletion_events
    SET pg_net_request_id = v_request_id
    WHERE id = p_event_id
      AND pg_net_request_id IS NULL;
  END IF;

  RAISE NOTICE 'fan team deleted push queued event=% team=% request_id=% recipients=%',
    p_event_id, v_team_id, v_request_id, cardinality(v_recipients);
EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      UPDATE public.fan_team_deleted_push_deliveries
      SET delivery_status = 'failed',
          skip_reason = left('queue_exception:' || SQLERRM, 200),
          updated_at = now()
      WHERE event_id = p_event_id
        AND delivery_status = 'queued';
    EXCEPTION
      WHEN OTHERS THEN
        NULL;
    END;
    RAISE NOTICE 'fan team deleted push queue failed event=% err=%', p_event_id, SQLERRM;
END;
$$;

REVOKE ALL ON FUNCTION public.queue_fan_team_deleted_push_notification(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.queue_fan_team_deleted_push_notification(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.queue_fan_team_deleted_push_notification(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.queue_fan_team_deleted_push_notification(uuid) TO service_role;

COMMENT ON FUNCTION public.queue_fan_team_deleted_push_notification(uuid) IS
  'Queues notify-fan-team-deleted via pg_net. Pre-inserts per-recipient delivery ledger '
  '(queued) and stores pg_net_request_id on fan_team_deletion_events. CRITICAL lifecycle '
  'push — Edge ignores Team mute.';

-- delete_fan_team recipient snapshot + soft-leave ordering is already correct in 20260933;
-- no change required here.

COMMIT;

-- Manual verification:
--   SELECT column_name FROM information_schema.columns
--   WHERE table_name='fan_team_deletion_events' AND column_name='pg_net_request_id';
-- Deploy Edge AFTER or with this migration (queued claim semantics):
--   supabase functions deploy notify-fan-team-deleted --no-verify-jwt
