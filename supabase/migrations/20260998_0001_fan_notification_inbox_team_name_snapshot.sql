-- =============================================================================
-- 20260998_0001 — Snapshot Team name onto Team event Inbox payloads
-- =============================================================================
-- Durable FanGeo Inbox history must keep Team: identity even if the Team is
-- later renamed or the cache is empty. fanout already resolved v_team_name for
-- titles but did not persist it on payload.
--
-- Recipients, dedupe, kind, destination, APNs pipeline unchanged.
-- PREPARE ONLY — do not auto-apply.
-- =============================================================================

DO $$
BEGIN
  IF to_regprocedure(
       'public.fanout_fan_notification_inbox_for_pickup_update_event(uuid)'
     ) IS NULL THEN
    RAISE EXCEPTION '20260998 missing fanout_fan_notification_inbox_for_pickup_update_event';
  END IF;
  IF to_regclass('public.fan_notification_inbox') IS NULL THEN
    RAISE EXCEPTION '20260998 missing fan_notification_inbox';
  END IF;
END $$;

BEGIN;

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
  v_override uuid[];
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

  IF v_notification_type IN ('join_request_approved', 'join_request_rejected') THEN
    v_title := 'Your request to join';
    v_body := v_game_title
      || CASE
           WHEN v_notification_type = 'join_request_approved' THEN ' was approved.'
           ELSE ' was declined.'
         END;
    v_kind_raw := 'scheduleChange';
    v_dest := 'scheduleActivity';
    v_dedupe := 'join_request_decision:'
      || lower(v_event.pickup_game_id::text)
      || ':'
      || lower(v_event.id::text);
  ELSIF v_notification_type IN ('team_announcement')
     OR (v_payload->>'is_team_announcement')::boolean IS TRUE THEN
    v_title := coalesce(v_team_name, 'Team') || ' announcement';
    v_body := v_game_title;
    v_kind_raw := 'scheduleChange';
    v_dest := 'scheduleActivity';
    v_dedupe := 'pickup_update:'
      || lower(v_event.pickup_game_id::text)
      || ':'
      || lower(v_event.id::text);
  ELSIF v_is_cancel THEN
    v_title := CASE
      WHEN v_team_name IS NOT NULL THEN v_team_name || ' event cancelled'
      ELSE 'Event cancelled'
    END;
    v_body := v_game_title;
    v_kind_raw := 'eventCancellation';
    v_dest := 'scheduleActivity';
    v_dedupe := 'pickup_cancel:'
      || lower(v_event.pickup_game_id::text)
      || ':'
      || lower(v_event.id::text);
  ELSIF v_notification_type IN ('team_game_created', 'created', 'team_event_created')
        OR 'created' = ANY (v_kinds) THEN
    v_title := CASE
      WHEN v_team_name IS NOT NULL THEN v_team_name || ' scheduled an event'
      ELSE 'New event'
    END;
    v_body := v_game_title;
    v_kind_raw := 'scheduleChange';
    v_dest := 'scheduleActivity';
    v_dedupe := 'pickup_update:'
      || lower(v_event.pickup_game_id::text)
      || ':'
      || lower(v_event.id::text);
  ELSIF v_notification_type IN ('time_and_location_changed') THEN
    v_title := CASE
      WHEN v_team_name IS NOT NULL THEN v_team_name || ' updated time & location'
      ELSE 'Time & location updated'
    END;
    v_body := v_game_title;
    v_kind_raw := 'scheduleChange';
    v_dest := 'scheduleActivity';
    v_dedupe := 'pickup_update:'
      || lower(v_event.pickup_game_id::text)
      || ':'
      || lower(v_event.id::text);
  ELSIF v_notification_type IN ('time_changed')
        OR 'start' = ANY (v_kinds) OR 'end' = ANY (v_kinds) THEN
    v_title := CASE
      WHEN v_team_name IS NOT NULL THEN v_team_name || ' updated the time'
      ELSE 'Event time updated'
    END;
    v_body := v_game_title;
    v_kind_raw := 'scheduleChange';
    v_dest := 'scheduleActivity';
    v_dedupe := 'pickup_update:'
      || lower(v_event.pickup_game_id::text)
      || ':'
      || lower(v_event.id::text);
  ELSIF v_notification_type IN ('location_changed') OR 'location' = ANY (v_kinds) THEN
    v_title := CASE
      WHEN v_team_name IS NOT NULL THEN v_team_name || ' updated the location'
      ELSE 'Event location updated'
    END;
    v_body := v_game_title;
    v_kind_raw := 'scheduleChange';
    v_dest := 'scheduleActivity';
    v_dedupe := 'pickup_update:'
      || lower(v_event.pickup_game_id::text)
      || ':'
      || lower(v_event.id::text);
  ELSE
    v_title := CASE
      WHEN v_team_name IS NOT NULL THEN v_team_name || ' updated an event'
      ELSE 'Event updated'
    END;
    v_body := v_game_title;
    v_kind_raw := 'scheduleChange';
    v_dest := 'scheduleActivity';
    v_dedupe := 'pickup_update:'
      || lower(v_event.pickup_game_id::text)
      || ':'
      || lower(v_event.id::text);
  END IF;

  SELECT coalesce(
    array_agg(DISTINCT x.uid) FILTER (WHERE x.uid IS NOT NULL),
    '{}'::uuid[]
  )
  INTO v_override
  FROM (
    SELECT NULLIF(btrim(j), '')::uuid AS uid
    FROM jsonb_array_elements_text(coalesce(v_payload->'recipient_user_ids', '[]'::jsonb)) AS j
  ) x;

  IF cardinality(v_override) > 0 THEN
    FOREACH v_uid IN ARRAY v_override LOOP
      IF public.upsert_fan_notification_inbox(
        p_user_id := v_uid,
        p_notification_type := v_notification_type,
        p_title := v_title,
        p_body := v_body,
        p_kind_raw := v_kind_raw,
        p_destination_raw := v_dest,
        p_deduplication_key := v_dedupe || ':' || lower(v_uid::text),
        p_source_type := 'pickup_game_change_notification',
        p_source_id := v_event.id::text,
        p_team_id := v_team_id,
        p_event_id := v_event.pickup_game_id,
        p_actor_user_id := v_event.editor_user_id,
        p_payload := v_payload || jsonb_build_object(
          'pickup_game_id', v_event.pickup_game_id,
          'pickup_update_event_id', v_event.id,
          'deduplication_key', v_dedupe || ':' || lower(v_uid::text),
          'change_kinds', to_jsonb(v_kinds),
          'safe_destination', v_dest,
          'team_id', v_team_id,
          'team_name', coalesce(v_team_name, v_payload->>'team_name')
        )
      ) IS NOT NULL THEN
        v_count := v_count + 1;
      END IF;
    END LOOP;
  ELSE
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
          'change_kinds', to_jsonb(v_kinds),
          'team_id', v_team_id,
          'team_name', coalesce(v_team_name, v_payload->>'team_name')
        )
      ) IS NOT NULL THEN
        v_count := v_count + 1;
      END IF;
    END LOOP;
  END IF;

  RAISE LOG
    '[FanNotificationInbox] pickupFanout update_event_id=% pickup_game_id=% type=% recipients=%',
    p_update_event_id, v_event.pickup_game_id, v_notification_type, v_count;

  RETURN v_count;
END;
$$;

COMMENT ON FUNCTION public.fanout_fan_notification_inbox_for_pickup_update_event(uuid) IS
  'Durable inbox fan-out for pickup/Team schedule events. Snapshots team_name '
  'onto payload for historical Team identity. Honors payload.recipient_user_ids '
  'when present (join-request decisions). Independent of APNs.';

REVOKE ALL ON FUNCTION public.fanout_fan_notification_inbox_for_pickup_update_event(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fanout_fan_notification_inbox_for_pickup_update_event(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.fanout_fan_notification_inbox_for_pickup_update_event(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.fanout_fan_notification_inbox_for_pickup_update_event(uuid) TO service_role;

DO $$
DECLARE
  v_src text;
BEGIN
  SELECT p.prosrc INTO v_src
  FROM pg_catalog.pg_proc p
  WHERE p.oid = to_regprocedure(
    'public.fanout_fan_notification_inbox_for_pickup_update_event(uuid)'
  );
  IF position('coalesce(v_team_name, v_payload' IN v_src) = 0 THEN
    RAISE EXCEPTION '20260998 fanout must snapshot team_name';
  END IF;
  IF position('recipient_user_ids' IN v_src) = 0 THEN
    RAISE EXCEPTION '20260998 fanout lost join-request recipient override';
  END IF;
END $$;

COMMIT;
