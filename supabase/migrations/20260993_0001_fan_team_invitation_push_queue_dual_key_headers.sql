-- =============================================================================
-- 20260993_0001 — Dual-key headers for Team invitation APNs queue
-- =============================================================================
-- Real-device: User A invited User B to IMC Team. FanGeo Inbox → Action Needed
-- showed "You're invited to IMC Team" (mutation + durable inbox OK). No iOS
-- banner outside the app.
--
-- Inbox is independent of APNs (list_my_pending_fan_team_invitations /
-- Action Needed). APNs is queued by queue_fan_team_invitation_push_notification
-- → pg_net POST /functions/v1/notify-fan-team-invitation.
--
-- Last queue rewrite (20260942) still sent Authorization: Bearer only and
-- preferred Vault SUPABASE_SERVICE_ROLE_KEY over fangeo_service_role_key.
-- Hosted Edge SERVICE_ROLE_KEY is often sb_secret_* after the dual-key
-- cutover. authorizeSportsWorkerRequest then returns invalid_secret (401)
-- before user_push_tokens / ApnsClient.send — same class as 20260988
-- (pickup) and 20260990 (member-change).
--
-- This migration does NOT weaken auth. It only:
--   1) Prefers Vault fangeo_service_role_key, then SUPABASE_SERVICE_ROLE_KEY
--   2) Sends the same Vault value on BOTH Authorization: Bearer and apikey
--   3) Sends both cron header names when a cron secret is present
--
-- Edge notify-fan-team-invitation already uses authorizeSportsWorkerRequest.
-- Redeploy that function so hosted auth matches local (apikey + JWT + cron).
--
-- Does NOT:
--   - change invite acceptance / fan_team_invitations rows
--   - create a second invitation or a second APNs sender
--   - change durable Inbox Action Needed
--   - edit already-applied 20260929 / 20260942
--
-- PREPARE ONLY — do not apply from the agent unless instructed.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.queue_fan_team_invitation_push_notification(
  p_invitation_id uuid,
  p_event_id uuid,
  p_kind text DEFAULT 'invite'
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
  v_kind text := lower(btrim(coalesce(p_kind, 'invite')));
  v_invitee uuid;
  v_inviter uuid;
  v_team_id uuid;
  v_request_id bigint;
BEGIN
  IF p_invitation_id IS NULL OR p_event_id IS NULL THEN
    RETURN;
  END IF;

  IF v_kind NOT IN ('invite', 'resend', 'create') THEN
    v_kind := 'invite';
  END IF;

  SELECT i.invitee_user_id, i.inviter_user_id, i.team_id
  INTO v_invitee, v_inviter, v_team_id
  FROM public.fan_team_invitations i
  WHERE i.id = p_invitation_id;

  IF v_invitee IS NULL OR v_inviter IS NULL OR v_team_id IS NULL THEN
    RAISE NOTICE 'fan team invitation push skipped: invitation missing invitation=%', p_invitation_id;
    RETURN;
  END IF;

  IF to_regnamespace('net') IS NULL OR to_regclass('vault.decrypted_secrets') IS NULL THEN
    INSERT INTO public.fan_team_invitation_push_deliveries (
      event_id, invitation_id, recipient_user_id, inviter_user_id, team_id,
      delivery_status, skip_reason, kind
    ) VALUES (
      p_event_id, p_invitation_id, v_invitee, v_inviter, v_team_id,
      'skipped', 'pg_net_or_vault_unavailable', v_kind
    )
    ON CONFLICT (event_id) DO NOTHING;
    RAISE NOTICE 'fan team invitation push skipped: pg_net or vault unavailable invitation=% event=%',
      p_invitation_id, p_event_id;
    RETURN;
  END IF;

  SELECT rtrim(decrypted_secret, '/')
  INTO v_url
  FROM vault.decrypted_secrets
  WHERE name IN ('fangeo_supabase_url', 'SUPABASE_URL')
    AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
  ORDER BY CASE name WHEN 'fangeo_supabase_url' THEN 0 ELSE 1 END
  LIMIT 1;

  -- Prefer the FanGeo Vault JWT (same name the Edge authorizer mirrors),
  -- then platform SUPABASE_SERVICE_ROLE_KEY. Dual-key headers below let
  -- authorizeSportsWorkerRequest accept JWT Bearer and/or sb_secret apikey.
  SELECT decrypted_secret
  INTO v_service_role_key
  FROM vault.decrypted_secrets
  WHERE name IN ('fangeo_service_role_key', 'SUPABASE_SERVICE_ROLE_KEY')
    AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
  ORDER BY CASE name WHEN 'fangeo_service_role_key' THEN 0 ELSE 1 END
  LIMIT 1;

  IF v_url IS NULL OR v_service_role_key IS NULL THEN
    INSERT INTO public.fan_team_invitation_push_deliveries (
      event_id, invitation_id, recipient_user_id, inviter_user_id, team_id,
      delivery_status, skip_reason, kind
    ) VALUES (
      p_event_id, p_invitation_id, v_invitee, v_inviter, v_team_id,
      'skipped', 'vault_secrets_missing', v_kind
    )
    ON CONFLICT (event_id) DO NOTHING;
    RAISE NOTICE 'fan team invitation push skipped: vault secrets missing invitation=% event=%',
      p_invitation_id, p_event_id;
    RETURN;
  END IF;

  SELECT decrypted_secret
  INTO v_cron_secret
  FROM vault.decrypted_secrets
  WHERE name = 'FAN_TEAM_INVITATION_PUSH_CRON_SECRET'
    AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
  ORDER BY updated_at DESC NULLS LAST, created_at DESC
  LIMIT 1;

  -- Dual-key: same Vault value on Bearer + apikey (20260988 / 20260990 class).
  -- Never log the secret.
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

  -- Pre-insert ledger BEFORE enqueue so cooldown/resend means "attempt recorded"
  -- even if Edge never runs. Edge treats status=queued as claimable.
  INSERT INTO public.fan_team_invitation_push_deliveries (
    event_id, invitation_id, recipient_user_id, inviter_user_id, team_id,
    delivery_status, kind
  ) VALUES (
    p_event_id, p_invitation_id, v_invitee, v_inviter, v_team_id,
    'queued', v_kind
  )
  ON CONFLICT (event_id) DO NOTHING;

  SELECT net.http_post(
    url := v_url || '/functions/v1/notify-fan-team-invitation',
    headers := v_headers,
    body := jsonb_build_object(
      'invitation_id', p_invitation_id,
      'event_id', p_event_id,
      'kind', v_kind
    ),
    timeout_milliseconds := 15000
  ) INTO v_request_id;

  IF v_request_id IS NOT NULL THEN
    UPDATE public.fan_team_invitation_push_deliveries
    SET pg_net_request_id = v_request_id,
        updated_at = now()
    WHERE event_id = p_event_id
      AND pg_net_request_id IS NULL;
  END IF;

  RAISE NOTICE
    'fan team invitation push queued invitation=% event=% request_id=% kind=%',
    p_invitation_id, p_event_id, v_request_id, v_kind;
EXCEPTION
  WHEN OTHERS THEN
    -- Best-effort failure ledger (do not fail invite TX).
    BEGIN
      INSERT INTO public.fan_team_invitation_push_deliveries (
        event_id, invitation_id, recipient_user_id, inviter_user_id, team_id,
        delivery_status, skip_reason, kind
      )
      SELECT
        p_event_id, p_invitation_id, i.invitee_user_id, i.inviter_user_id, i.team_id,
        'failed', left('queue_exception:' || SQLERRM, 200), v_kind
      FROM public.fan_team_invitations i
      WHERE i.id = p_invitation_id
      ON CONFLICT (event_id) DO UPDATE
        SET delivery_status = EXCLUDED.delivery_status,
            skip_reason = EXCLUDED.skip_reason,
            updated_at = now()
        WHERE public.fan_team_invitation_push_deliveries.delivery_status = 'queued';
    EXCEPTION
      WHEN OTHERS THEN
        NULL; -- swallow nested
    END;
    RAISE NOTICE 'fan team invitation push queue failed invitation=% event=% err=%',
      p_invitation_id, p_event_id, SQLERRM;
END;
$$;

-- Keep 2-arg call sites working (create/invite helper).
CREATE OR REPLACE FUNCTION public.queue_fan_team_invitation_push_notification(
  p_invitation_id uuid,
  p_event_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.queue_fan_team_invitation_push_notification(p_invitation_id, p_event_id, 'invite');
END;
$$;

REVOKE ALL ON FUNCTION public.queue_fan_team_invitation_push_notification(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.queue_fan_team_invitation_push_notification(uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.queue_fan_team_invitation_push_notification(uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.queue_fan_team_invitation_push_notification(uuid, uuid) TO service_role;

REVOKE ALL ON FUNCTION public.queue_fan_team_invitation_push_notification(uuid, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.queue_fan_team_invitation_push_notification(uuid, uuid, text) FROM anon;
REVOKE ALL ON FUNCTION public.queue_fan_team_invitation_push_notification(uuid, uuid, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.queue_fan_team_invitation_push_notification(uuid, uuid, text) TO service_role;

COMMENT ON FUNCTION public.queue_fan_team_invitation_push_notification(uuid, uuid, text) IS
  'pg_net POST to notify-fan-team-invitation with dual-key Bearer+apikey from Vault. '
  'Pre-inserts delivery ledger. Independent of durable FanGeo Inbox Action Needed.';

COMMENT ON FUNCTION public.queue_fan_team_invitation_push_notification(uuid, uuid) IS
  'Delegates to queue_fan_team_invitation_push_notification(uuid, uuid, text) with kind=invite.';

DO $$
DECLARE
  v_src text;
BEGIN
  SELECT pg_get_functiondef(
    'public.queue_fan_team_invitation_push_notification(uuid, uuid, text)'::regprocedure
  ) INTO v_src;

  IF v_src IS NULL OR position('apikey' in v_src) = 0 THEN
    RAISE EXCEPTION
      '20260993: queue_fan_team_invitation_push_notification must send apikey header';
  END IF;

  IF position('''Authorization'', ''Bearer '' || v_service_role_key' in v_src) = 0 THEN
    RAISE EXCEPTION
      '20260993: queue_fan_team_invitation_push_notification must keep Bearer Authorization';
  END IF;

  IF position('fangeo_service_role_key' in v_src) = 0 THEN
    RAISE EXCEPTION
      '20260993: queue must read Vault fangeo_service_role_key';
  END IF;

  IF position('notify-fan-team-invitation' in v_src) = 0 THEN
    RAISE EXCEPTION
      '20260993: queue must still POST notify-fan-team-invitation';
  END IF;

  IF position('WHEN ''SUPABASE_SERVICE_ROLE_KEY'' THEN 0' in v_src) > 0 THEN
    RAISE EXCEPTION
      '20260993: vault lookup must prefer fangeo_service_role_key, not SUPABASE_SERVICE_ROLE_KEY';
  END IF;
END;
$$;

NOTIFY pgrst, 'reload schema';
