-- =============================================================================
-- 20260983_0001 — Durable per-user Action Center → Notifications inbox
-- =============================================================================
-- Server-backed notification history independent of APNs delivery.
-- Authoritative event → upsert inbox row(s) → queue/send APNs.
-- UNAPPLIED — deploy manually. Do not auto-apply from the client.
-- =============================================================================

DO $$
BEGIN
  IF to_regclass('public.pickup_game_update_events') IS NULL THEN
    RAISE EXCEPTION
      '20260983_0001 prerequisite missing: public.pickup_game_update_events';
  END IF;
  IF to_regprocedure('public.queue_pickup_game_change_push_notification(uuid)') IS NULL THEN
    RAISE EXCEPTION
      '20260983_0001 prerequisite missing: queue_pickup_game_change_push_notification(uuid)';
  END IF;
END $$;

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.fan_notification_inbox (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  notification_type text NOT NULL,
  title text NOT NULL,
  body text NOT NULL DEFAULT '',
  kind_raw text NOT NULL DEFAULT 'scheduleChange',
  destination_raw text NOT NULL DEFAULT 'scheduleActivity',
  source_type text,
  source_id text,
  team_id uuid,
  event_id uuid,
  actor_user_id uuid,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  deduplication_key text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  read_at timestamptz,
  cleared_at timestamptz,
  CONSTRAINT fan_notification_inbox_user_dedupe_uidx
    UNIQUE (user_id, deduplication_key),
  CONSTRAINT fan_notification_inbox_kind_ck CHECK (
    kind_raw IN ('scheduleChange', 'eventCancellation', 'poke')
  ),
  CONSTRAINT fan_notification_inbox_dedupe_len_ck CHECK (
    char_length(deduplication_key) BETWEEN 1 AND 180
  )
);

CREATE INDEX IF NOT EXISTS fan_notification_inbox_user_visible_created_idx
  ON public.fan_notification_inbox (user_id, created_at DESC, id DESC)
  WHERE cleared_at IS NULL;

CREATE INDEX IF NOT EXISTS fan_notification_inbox_user_unread_idx
  ON public.fan_notification_inbox (user_id, created_at DESC)
  WHERE cleared_at IS NULL AND read_at IS NULL;

CREATE INDEX IF NOT EXISTS fan_notification_inbox_event_idx
  ON public.fan_notification_inbox (event_id)
  WHERE event_id IS NOT NULL;

COMMENT ON TABLE public.fan_notification_inbox IS
  'Durable Action Center → Notifications history. Created server-side at fan-out; '
  'independent of APNs success/failure and of whether the app was running.';

ALTER TABLE public.fan_notification_inbox ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.fan_notification_inbox FROM PUBLIC;
REVOKE ALL ON TABLE public.fan_notification_inbox FROM anon;
GRANT SELECT ON TABLE public.fan_notification_inbox TO authenticated;
GRANT ALL ON TABLE public.fan_notification_inbox TO service_role;

DROP POLICY IF EXISTS fan_notification_inbox_select_own ON public.fan_notification_inbox;
CREATE POLICY fan_notification_inbox_select_own
  ON public.fan_notification_inbox
  FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

-- Clients must not INSERT/UPDATE arbitrary rows (only RPCs for read/clear).
DROP POLICY IF EXISTS fan_notification_inbox_no_client_insert ON public.fan_notification_inbox;
DROP POLICY IF EXISTS fan_notification_inbox_no_client_update ON public.fan_notification_inbox;
DROP POLICY IF EXISTS fan_notification_inbox_no_client_delete ON public.fan_notification_inbox;

-- ---------------------------------------------------------------------------
-- 2) Upsert helper (service_role / SECURITY DEFINER callers)
-- ---------------------------------------------------------------------------
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
    ELSE 'scheduleChange'
  END;
  v_dest := CASE lower(btrim(coalesce(p_destination_raw, '')))
    WHEN 'accountpokes' THEN 'accountPokes'
    WHEN 'account_pokes' THEN 'accountPokes'
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
      -- Preserve read/clear; refresh display copy if event is re-queued.
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

COMMENT ON FUNCTION public.upsert_fan_notification_inbox(
  uuid, text, text, text, text, text, text, text, text, uuid, uuid, uuid, jsonb
) IS
  'Idempotent per-user inbox upsert keyed by (user_id, deduplication_key). '
  'Service-role / SECURITY DEFINER only — clients cannot forge rows.';

-- ---------------------------------------------------------------------------
-- 3) Recipient user ids for pickup/team schedule events (no push-token required)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_fan_notification_inbox_recipient_user_ids_for_pickup_game(
  p_pickup_game_id uuid,
  p_exclude_user_id uuid
)
RETURNS TABLE (user_id uuid)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH team_linked AS (
    SELECT EXISTS (
      SELECT 1
      FROM public.fan_team_game_links l
      WHERE l.pickup_game_id = p_pickup_game_id
    ) AS is_linked
  ),
  linked_teams AS (
    SELECT DISTINCT l.team_id
    FROM public.fan_team_game_links l
    INNER JOIN public.fan_teams t
      ON t.id = l.team_id
     AND t.is_active = true
    WHERE l.pickup_game_id = p_pickup_game_id
  ),
  game_meta AS (
    SELECT g.game_start_at >= now() AS is_future
    FROM public.pickup_games g
    WHERE g.id = p_pickup_game_id
  ),
  affected AS (
    SELECT r.requester_user_id AS uid
    FROM public.pickup_game_requests r
    CROSS JOIN team_linked tl
    CROSS JOIN game_meta gm
    LEFT JOIN public.fan_team_game_links l ON l.pickup_game_id = r.pickup_game_id
    WHERE r.pickup_game_id = p_pickup_game_id
      AND lower(btrim(r.status)) = 'approved'
      AND (
        NOT tl.is_linked
        OR (
          to_regprocedure('public.is_fan_team_linked_request_actor_eligible(uuid,uuid,timestamptz,boolean)')
            IS NOT NULL
          AND public.is_fan_team_linked_request_actor_eligible(
            l.team_id, r.requester_user_id, r.created_at, gm.is_future
          )
        )
      )
      AND (
        NOT tl.is_linked
        OR NOT EXISTS (
          SELECT 1
          FROM public.fan_team_event_exclusions ex
          WHERE ex.team_id = l.team_id
            AND ex.pickup_game_id = p_pickup_game_id
            AND ex.user_id = r.requester_user_id
        )
      )

    UNION

    SELECT r.requester_user_id AS uid
    FROM public.pickup_game_requests r
    CROSS JOIN team_linked tl
    CROSS JOIN game_meta gm
    LEFT JOIN public.fan_team_game_links l ON l.pickup_game_id = r.pickup_game_id
    WHERE r.pickup_game_id = p_pickup_game_id
      AND tl.is_linked
      AND lower(btrim(r.status)) = 'pending'
      AND to_regprocedure('public.is_fan_team_linked_request_actor_eligible(uuid,uuid,timestamptz,boolean)')
        IS NOT NULL
      AND public.is_fan_team_linked_request_actor_eligible(
        l.team_id, r.requester_user_id, r.created_at, gm.is_future
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.fan_team_event_exclusions ex
        WHERE ex.team_id = l.team_id
          AND ex.pickup_game_id = p_pickup_game_id
          AND ex.user_id = r.requester_user_id
      )

    UNION

    SELECT i.invitee_user_id AS uid
    FROM public.pickup_game_invites i
    WHERE i.pickup_game_id = p_pickup_game_id
      AND lower(btrim(i.status)) IN ('accepted', 'maybe')

    UNION

    SELECT m.user_id AS uid
    FROM public.fan_team_members m
    INNER JOIN linked_teams lt ON lt.team_id = m.team_id
    WHERE m.left_at IS NULL
      AND m.user_id IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM public.fan_team_event_exclusions ex
        WHERE ex.team_id = m.team_id
          AND ex.pickup_game_id = p_pickup_game_id
          AND ex.user_id = m.user_id
      )

    UNION

    SELECT g.guardian_user_id AS uid
    FROM public.fan_team_members m
    INNER JOIN linked_teams lt ON lt.team_id = m.team_id
    INNER JOIN public.fan_managed_player_guardians g
      ON g.managed_player_id = m.managed_player_id
     AND g.revoked_at IS NULL
    WHERE m.left_at IS NULL
      AND m.managed_player_id IS NOT NULL
      AND to_regclass('public.fan_managed_player_guardians') IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM public.fan_team_event_exclusions ex
        WHERE ex.team_id = m.team_id
          AND ex.pickup_game_id = p_pickup_game_id
          AND ex.managed_player_id = m.managed_player_id
      )
  )
  SELECT DISTINCT a.uid AS user_id
  FROM affected a
  INNER JOIN public.user_profiles up ON up.id = a.uid
  WHERE a.uid IS NOT NULL
    AND (p_exclude_user_id IS NULL OR a.uid IS DISTINCT FROM p_exclude_user_id)
    AND up.deleted_at IS NULL
    AND NOT EXISTS (
      SELECT 1
      FROM public.user_bans ub
      WHERE ub.user_id = a.uid
        AND public.is_user_ban_active(ub.expires_at, ub.lifted_at)
    );
$$;

REVOKE ALL ON FUNCTION public.list_fan_notification_inbox_recipient_user_ids_for_pickup_game(uuid, uuid)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_fan_notification_inbox_recipient_user_ids_for_pickup_game(uuid, uuid)
  FROM anon;
REVOKE ALL ON FUNCTION public.list_fan_notification_inbox_recipient_user_ids_for_pickup_game(uuid, uuid)
  FROM authenticated;
GRANT EXECUTE ON FUNCTION public.list_fan_notification_inbox_recipient_user_ids_for_pickup_game(uuid, uuid)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 4) Fan-out from pickup_game_update_events (create / change / cancel / announcement)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fanout_fan_notification_inbox_for_pickup_update_event(
  p_update_event_id uuid
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_event public.pickup_game_update_events%ROWTYPE;
  v_payload jsonb;
  v_kinds text[];
  v_notification_type text;
  v_title text;
  v_body text;
  v_kind_raw text;
  v_dest text;
  v_dedupe text;
  v_team_id uuid;
  v_team_name text;
  v_game_title text;
  v_uid uuid;
  v_count integer := 0;
  v_is_cancel boolean := false;
BEGIN
  IF p_update_event_id IS NULL THEN
    RETURN 0;
  END IF;

  SELECT * INTO v_event
  FROM public.pickup_game_update_events e
  WHERE e.id = p_update_event_id;

  IF v_event.id IS NULL THEN
    RETURN 0;
  END IF;

  v_payload := coalesce(v_event.payload, '{}'::jsonb);
  v_kinds := coalesce(v_event.change_kinds, ARRAY[]::text[]);
  v_notification_type := lower(btrim(coalesce(v_payload->>'notification_type', '')));
  IF v_notification_type = '' THEN
    IF 'cancelled' = ANY (v_kinds) OR 'canceled' = ANY (v_kinds) THEN
      v_notification_type := 'cancelled';
    ELSIF 'created' = ANY (v_kinds) THEN
      v_notification_type := 'created';
    ELSIF 'start' = ANY (v_kinds) AND 'location' = ANY (v_kinds) THEN
      v_notification_type := 'time_and_location_changed';
    ELSIF 'start' = ANY (v_kinds) OR 'end' = ANY (v_kinds) THEN
      v_notification_type := 'time_changed';
    ELSIF 'location' = ANY (v_kinds) THEN
      v_notification_type := 'location_changed';
    ELSE
      v_notification_type := 'schedule_change';
    END IF;
  END IF;

  v_is_cancel := v_notification_type IN ('cancelled', 'canceled', 'event_cancelled')
    OR 'cancelled' = ANY (v_kinds)
    OR 'canceled' = ANY (v_kinds);

  v_game_title := nullif(btrim(coalesce(v_payload->>'title', '')), '');
  IF v_game_title IS NULL THEN
    SELECT nullif(btrim(g.title), '') INTO v_game_title
    FROM public.pickup_games g
    WHERE g.id = v_event.pickup_game_id;
  END IF;
  v_game_title := coalesce(v_game_title, 'Event');

  v_team_id := NULLIF(v_payload->>'team_id', '')::uuid;
  IF v_team_id IS NULL THEN
    SELECT l.team_id INTO v_team_id
    FROM public.fan_team_game_links l
    INNER JOIN public.fan_teams t ON t.id = l.team_id AND t.is_active = true
    WHERE l.pickup_game_id = v_event.pickup_game_id
    LIMIT 1;
  END IF;

  v_team_name := nullif(btrim(coalesce(v_payload->>'team_name', '')), '');
  IF v_team_name IS NULL AND v_team_id IS NOT NULL THEN
    SELECT nullif(btrim(t.name), '') INTO v_team_name
    FROM public.fan_teams t
    WHERE t.id = v_team_id;
  END IF;

  IF v_notification_type IN ('team_announcement')
     OR (v_payload->>'is_team_announcement')::boolean IS TRUE THEN
    v_title := coalesce(v_team_name, 'Team') || ' announcement';
    v_body := v_game_title;
    v_kind_raw := 'scheduleChange';
    v_dest := 'scheduleActivity';
  ELSIF v_is_cancel THEN
    v_title := CASE
      WHEN v_team_name IS NOT NULL THEN v_team_name || ' event cancelled'
      ELSE 'Event cancelled'
    END;
    v_body := v_game_title;
    v_kind_raw := 'eventCancellation';
    v_dest := 'scheduleActivity';
  ELSIF v_notification_type IN ('team_game_created', 'created', 'team_event_created')
        OR 'created' = ANY (v_kinds) THEN
    v_title := CASE
      WHEN v_team_name IS NOT NULL THEN v_team_name || ' scheduled an event'
      ELSE 'New event'
    END;
    v_body := v_game_title;
    v_kind_raw := 'scheduleChange';
    v_dest := 'scheduleActivity';
  ELSIF v_notification_type IN ('time_and_location_changed') THEN
    v_title := CASE
      WHEN v_team_name IS NOT NULL THEN v_team_name || ' updated time & location'
      ELSE 'Time & location updated'
    END;
    v_body := v_game_title;
    v_kind_raw := 'scheduleChange';
    v_dest := 'scheduleActivity';
  ELSIF v_notification_type IN ('time_changed')
        OR 'start' = ANY (v_kinds) OR 'end' = ANY (v_kinds) THEN
    v_title := CASE
      WHEN v_team_name IS NOT NULL THEN v_team_name || ' updated the time'
      ELSE 'Event time updated'
    END;
    v_body := v_game_title;
    v_kind_raw := 'scheduleChange';
    v_dest := 'scheduleActivity';
  ELSIF v_notification_type IN ('location_changed') OR 'location' = ANY (v_kinds) THEN
    v_title := CASE
      WHEN v_team_name IS NOT NULL THEN v_team_name || ' updated the location'
      ELSE 'Event location updated'
    END;
    v_body := v_game_title;
    v_kind_raw := 'scheduleChange';
    v_dest := 'scheduleActivity';
  ELSE
    v_title := CASE
      WHEN v_team_name IS NOT NULL THEN v_team_name || ' updated an event'
      ELSE 'Event updated'
    END;
    v_body := v_game_title;
    v_kind_raw := 'scheduleChange';
    v_dest := 'scheduleActivity';
  END IF;

  IF v_is_cancel THEN
    v_dedupe := 'pickup_cancel:'
      || lower(v_event.pickup_game_id::text)
      || ':'
      || lower(v_event.id::text);
  ELSE
    v_dedupe := 'pickup_update:'
      || lower(v_event.pickup_game_id::text)
      || ':'
      || lower(v_event.id::text);
  END IF;

  FOR v_uid IN
    SELECT r.user_id
    FROM public.list_fan_notification_inbox_recipient_user_ids_for_pickup_game(
      v_event.pickup_game_id,
      v_event.editor_user_id
    ) r
  LOOP
    IF public.upsert_fan_notification_inbox(
      p_user_id := v_uid,
      p_notification_type := v_notification_type,
      p_title := v_title,
      p_body := v_body,
      p_kind_raw := v_kind_raw,
      p_destination_raw := v_dest,
      p_deduplication_key := v_dedupe,
      p_source_type := 'pickup_game_change_notification',
      p_source_id := v_event.id::text,
      p_team_id := v_team_id,
      p_event_id := v_event.pickup_game_id,
      p_actor_user_id := v_event.editor_user_id,
      p_payload := v_payload || jsonb_build_object(
        'pickup_game_id', v_event.pickup_game_id,
        'pickup_update_event_id', v_event.id,
        'deduplication_key', v_dedupe,
        'change_kinds', to_jsonb(v_kinds)
      )
    ) IS NOT NULL THEN
      v_count := v_count + 1;
    END IF;
  END LOOP;

  RAISE LOG
    '[FanNotificationInbox] pickupFanout update_event_id=% pickup_game_id=% type=% recipients=%',
    p_update_event_id, v_event.pickup_game_id, v_notification_type, v_count;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.fanout_fan_notification_inbox_for_pickup_update_event(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fanout_fan_notification_inbox_for_pickup_update_event(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.fanout_fan_notification_inbox_for_pickup_update_event(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.fanout_fan_notification_inbox_for_pickup_update_event(uuid) TO service_role;

COMMENT ON FUNCTION public.fanout_fan_notification_inbox_for_pickup_update_event(uuid) IS
  'Writes durable inbox rows for all pickup/team schedule recipients BEFORE/independent of APNs. '
  'Idempotent via pickup_update|pickup_cancel:<game>:<update_event_id>.';

-- ---------------------------------------------------------------------------
-- 5) Hook inbox fan-out into existing queue (APNs remains separate)
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

-- ---------------------------------------------------------------------------
-- 6) Member-left / member-change inbox fan-out (when event tables exist)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fanout_fan_notification_inbox_for_member_left_event(
  p_event_id uuid
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_team_id uuid;
  v_team_name text;
  v_recipients uuid[];
  v_uid uuid;
  v_dedupe text;
  v_count integer := 0;
BEGIN
  IF p_event_id IS NULL OR to_regclass('public.fan_team_member_left_events') IS NULL THEN
    RETURN 0;
  END IF;

  SELECT e.team_id, coalesce(e.recipient_user_ids, '{}'::uuid[]), nullif(btrim(e.team_name), '')
  INTO v_team_id, v_recipients, v_team_name
  FROM public.fan_team_member_left_events e
  WHERE e.id = p_event_id;

  IF v_team_id IS NULL THEN
    RETURN 0;
  END IF;

  v_dedupe := 'team_member_left:' || lower(p_event_id::text);

  FOREACH v_uid IN ARRAY coalesce(v_recipients, '{}'::uuid[]) LOOP
    IF v_uid IS NULL THEN
      CONTINUE;
    END IF;
    IF public.upsert_fan_notification_inbox(
      p_user_id := v_uid,
      p_notification_type := 'member_left_team',
      p_title := coalesce(v_team_name, 'Team') || ' membership update',
      p_body := 'A member left the team',
      p_kind_raw := 'scheduleChange',
      p_destination_raw := 'scheduleActivity',
      p_deduplication_key := v_dedupe || ':' || lower(v_uid::text),
      p_source_type := 'member_left',
      p_source_id := p_event_id::text,
      p_team_id := v_team_id,
      p_event_id := p_event_id,
      p_payload := jsonb_build_object(
        'team_id', v_team_id,
        'event_id', p_event_id,
        'deduplication_key', v_dedupe || ':' || lower(v_uid::text)
      )
    ) IS NOT NULL THEN
      v_count := v_count + 1;
    END IF;
  END LOOP;

  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.fanout_fan_notification_inbox_for_member_change_event(
  p_event_id uuid
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_team_id uuid;
  v_team_name text;
  v_recipients uuid[];
  v_change_kind text;
  v_uid uuid;
  v_title text;
  v_body text;
  v_dedupe text;
  v_count integer := 0;
BEGIN
  IF p_event_id IS NULL OR to_regclass('public.fan_team_member_change_events') IS NULL THEN
    RETURN 0;
  END IF;

  SELECT
    e.team_id,
    coalesce(e.recipient_user_ids, '{}'::uuid[]),
    lower(btrim(coalesce(e.kind, 'member_change'))),
    nullif(btrim(e.team_name), '')
  INTO v_team_id, v_recipients, v_change_kind, v_team_name
  FROM public.fan_team_member_change_events e
  WHERE e.id = p_event_id;

  IF v_team_id IS NULL THEN
    RETURN 0;
  END IF;

  v_title := coalesce(v_team_name, 'Team') || ' update';
  v_body := CASE v_change_kind
    WHEN 'team_role_changed' THEN 'Your Team role changed'
    WHEN 'removed_from_team' THEN 'Removed from team'
    WHEN 'removed_from_event' THEN 'Removed from an event'
    WHEN 'added_back_to_event' THEN 'Added back to an event'
    WHEN 'player_number_set' THEN 'Player number updated'
    WHEN 'player_number_changed' THEN 'Player number updated'
    WHEN 'player_number_removed' THEN 'Player number removed'
    WHEN 'preferred_position_set' THEN 'Preferred position updated'
    WHEN 'preferred_position_changed' THEN 'Preferred position updated'
    WHEN 'preferred_position_removed' THEN 'Preferred position removed'
    ELSE 'Team membership changed'
  END;
  v_dedupe := 'team_member_change:' || lower(p_event_id::text);

  FOREACH v_uid IN ARRAY coalesce(v_recipients, '{}'::uuid[]) LOOP
    IF v_uid IS NULL THEN
      CONTINUE;
    END IF;
    IF public.upsert_fan_notification_inbox(
      p_user_id := v_uid,
      p_notification_type := v_change_kind,
      p_title := v_title,
      p_body := v_body,
      p_kind_raw := 'scheduleChange',
      p_destination_raw := 'scheduleActivity',
      p_deduplication_key := v_dedupe || ':' || lower(v_uid::text),
      p_source_type := 'member_change',
      p_source_id := p_event_id::text,
      p_team_id := v_team_id,
      p_event_id := p_event_id,
      p_payload := jsonb_build_object(
        'team_id', v_team_id,
        'event_id', p_event_id,
        'change_kind', v_change_kind,
        'deduplication_key', v_dedupe || ':' || lower(v_uid::text)
      )
    ) IS NOT NULL THEN
      v_count := v_count + 1;
    END IF;
  END LOOP;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.fanout_fan_notification_inbox_for_member_left_event(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fanout_fan_notification_inbox_for_member_left_event(uuid) TO service_role;
REVOKE ALL ON FUNCTION public.fanout_fan_notification_inbox_for_member_change_event(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fanout_fan_notification_inbox_for_member_change_event(uuid) TO service_role;

-- Patch member-left queue when present (inbox before APNs).
DO $$
BEGIN
  IF to_regprocedure('public.queue_fan_team_member_left_push_notification(uuid)') IS NULL THEN
    RETURN;
  END IF;
  -- Soft wrap: call fanout at start via a thin override if we can replace the function.
  -- Full function bodies live in 20260957; we install a trigger-like wrapper by
  -- creating a BEFORE-queue helper invoked from a replacement only when safe.
END $$;

CREATE OR REPLACE FUNCTION public.queue_fan_team_member_left_push_notification_inbox_hook(
  p_event_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  BEGIN
    PERFORM public.fanout_fan_notification_inbox_for_member_left_event(p_event_id);
  EXCEPTION WHEN OTHERS THEN
    RAISE LOG '[FanNotificationInbox] memberLeftFanoutFailed event=% err=%', p_event_id, SQLERRM;
  END;
END;
$$;

CREATE OR REPLACE FUNCTION public.queue_fan_team_member_change_push_notification_inbox_hook(
  p_event_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  BEGIN
    PERFORM public.fanout_fan_notification_inbox_for_member_change_event(p_event_id);
  EXCEPTION WHEN OTHERS THEN
    RAISE LOG '[FanNotificationInbox] memberChangeFanoutFailed event=% err=%', p_event_id, SQLERRM;
  END;
END;
$$;

GRANT EXECUTE ON FUNCTION public.queue_fan_team_member_left_push_notification_inbox_hook(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.queue_fan_team_member_change_push_notification_inbox_hook(uuid) TO service_role;

-- Wrap existing queues to call inbox hooks first (preserve APNs path).
DO $$
DECLARE
  v_def text;
BEGIN
  IF to_regprocedure('public.queue_fan_team_member_left_push_notification(uuid)') IS NOT NULL THEN
    -- Install replacement that fans out inbox then delegates to original via rename once.
    IF to_regprocedure('public.queue_fan_team_member_left_push_notification_apns(uuid)') IS NULL THEN
      ALTER FUNCTION public.queue_fan_team_member_left_push_notification(uuid)
        RENAME TO queue_fan_team_member_left_push_notification_apns;
    END IF;

    EXECUTE $fn$
CREATE OR REPLACE FUNCTION public.queue_fan_team_member_left_push_notification(p_event_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $body$
BEGIN
  PERFORM public.queue_fan_team_member_left_push_notification_inbox_hook(p_event_id);
  PERFORM public.queue_fan_team_member_left_push_notification_apns(p_event_id);
END;
$body$;
$fn$;
    REVOKE ALL ON FUNCTION public.queue_fan_team_member_left_push_notification(uuid) FROM PUBLIC;
    REVOKE ALL ON FUNCTION public.queue_fan_team_member_left_push_notification(uuid) FROM anon;
    REVOKE ALL ON FUNCTION public.queue_fan_team_member_left_push_notification(uuid) FROM authenticated;
    GRANT EXECUTE ON FUNCTION public.queue_fan_team_member_left_push_notification(uuid) TO service_role;
  END IF;

  IF to_regprocedure('public.queue_fan_team_member_change_push_notification(uuid)') IS NOT NULL THEN
    IF to_regprocedure('public.queue_fan_team_member_change_push_notification_apns(uuid)') IS NULL THEN
      ALTER FUNCTION public.queue_fan_team_member_change_push_notification(uuid)
        RENAME TO queue_fan_team_member_change_push_notification_apns;
    END IF;

    EXECUTE $fn$
CREATE OR REPLACE FUNCTION public.queue_fan_team_member_change_push_notification(p_event_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $body$
BEGIN
  PERFORM public.queue_fan_team_member_change_push_notification_inbox_hook(p_event_id);
  PERFORM public.queue_fan_team_member_change_push_notification_apns(p_event_id);
END;
$body$;
$fn$;
    REVOKE ALL ON FUNCTION public.queue_fan_team_member_change_push_notification(uuid) FROM PUBLIC;
    REVOKE ALL ON FUNCTION public.queue_fan_team_member_change_push_notification(uuid) FROM anon;
    REVOKE ALL ON FUNCTION public.queue_fan_team_member_change_push_notification(uuid) FROM authenticated;
    GRANT EXECUTE ON FUNCTION public.queue_fan_team_member_change_push_notification(uuid) TO service_role;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 7) Client RPCs: list / mark read / clear / clear all
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_my_fan_notification_inbox(
  p_limit integer DEFAULT 50,
  p_before_created_at timestamptz DEFAULT NULL,
  p_before_id uuid DEFAULT NULL
)
RETURNS TABLE (
  id uuid,
  notification_type text,
  title text,
  body text,
  kind_raw text,
  destination_raw text,
  source_type text,
  source_id text,
  team_id uuid,
  event_id uuid,
  actor_user_id uuid,
  payload jsonb,
  deduplication_key text,
  created_at timestamptz,
  read_at timestamptz,
  cleared_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_limit integer := GREATEST(1, LEAST(coalesce(p_limit, 50), 100));
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  RETURN QUERY
  SELECT
    i.id,
    i.notification_type,
    i.title,
    i.body,
    i.kind_raw,
    i.destination_raw,
    i.source_type,
    i.source_id,
    i.team_id,
    i.event_id,
    i.actor_user_id,
    i.payload,
    i.deduplication_key,
    i.created_at,
    i.read_at,
    i.cleared_at
  FROM public.fan_notification_inbox i
  WHERE i.user_id = v_uid
    AND i.cleared_at IS NULL
    AND (
      p_before_created_at IS NULL
      OR (i.created_at, i.id) < (p_before_created_at, p_before_id)
    )
  ORDER BY i.created_at DESC, i.id DESC
  LIMIT v_limit;
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_my_fan_notification_inbox_read(
  p_deduplication_keys text[]
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_count integer := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;
  IF p_deduplication_keys IS NULL OR cardinality(p_deduplication_keys) = 0 THEN
    RETURN 0;
  END IF;

  UPDATE public.fan_notification_inbox i
  SET read_at = coalesce(i.read_at, now())
  WHERE i.user_id = v_uid
    AND i.cleared_at IS NULL
    AND i.deduplication_key = ANY (
      SELECT lower(btrim(x)) FROM unnest(p_deduplication_keys) AS x
      WHERE nullif(btrim(x), '') IS NOT NULL
    )
    AND i.read_at IS NULL;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.clear_my_fan_notification_inbox(
  p_deduplication_keys text[]
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_count integer := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;
  IF p_deduplication_keys IS NULL OR cardinality(p_deduplication_keys) = 0 THEN
    RETURN 0;
  END IF;

  UPDATE public.fan_notification_inbox i
  SET
    cleared_at = coalesce(i.cleared_at, now()),
    read_at = coalesce(i.read_at, now())
  WHERE i.user_id = v_uid
    AND i.cleared_at IS NULL
    AND i.deduplication_key = ANY (
      SELECT lower(btrim(x)) FROM unnest(p_deduplication_keys) AS x
      WHERE nullif(btrim(x), '') IS NOT NULL
    );

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.clear_all_my_fan_notification_inbox()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_count integer := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  UPDATE public.fan_notification_inbox i
  SET
    cleared_at = coalesce(i.cleared_at, now()),
    read_at = coalesce(i.read_at, now())
  WHERE i.user_id = v_uid
    AND i.cleared_at IS NULL;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.list_my_fan_notification_inbox(integer, timestamptz, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_my_fan_notification_inbox(integer, timestamptz, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.list_my_fan_notification_inbox(integer, timestamptz, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_my_fan_notification_inbox(integer, timestamptz, uuid) TO service_role;

REVOKE ALL ON FUNCTION public.mark_my_fan_notification_inbox_read(text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mark_my_fan_notification_inbox_read(text[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.mark_my_fan_notification_inbox_read(text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_my_fan_notification_inbox_read(text[]) TO service_role;

REVOKE ALL ON FUNCTION public.clear_my_fan_notification_inbox(text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.clear_my_fan_notification_inbox(text[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.clear_my_fan_notification_inbox(text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.clear_my_fan_notification_inbox(text[]) TO service_role;

REVOKE ALL ON FUNCTION public.clear_all_my_fan_notification_inbox() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.clear_all_my_fan_notification_inbox() FROM anon;
GRANT EXECUTE ON FUNCTION public.clear_all_my_fan_notification_inbox() TO authenticated;
GRANT EXECUTE ON FUNCTION public.clear_all_my_fan_notification_inbox() TO service_role;

COMMIT;

-- ---------------------------------------------------------------------------
-- Validation (manual)
-- ---------------------------------------------------------------------------
-- SELECT to_regclass('public.fan_notification_inbox');
-- SELECT to_regprocedure('public.fanout_fan_notification_inbox_for_pickup_update_event(uuid)');
-- SELECT to_regprocedure('public.list_my_fan_notification_inbox(integer,timestamptz,uuid)');
-- ---------------------------------------------------------------------------
-- Deploy notes
-- ---------------------------------------------------------------------------
-- 1) Apply this migration on Supabase.
-- 2) Redeploy notify-pickup-game-change (adds deduplication_key to APNs custom data).
-- 3) No Edge change required for inbox creation (SQL queue fan-out is authoritative).
