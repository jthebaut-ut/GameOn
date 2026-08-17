-- =============================================================================
-- 20260992_0001 — Join-request over-capacity approve + requester decision notify
-- =============================================================================
-- 1) Organizer may approve a pending join request even when preferred capacity
--    is already full. The iOS Request Review screen confirms first. Do not
--    silently reject (pickup_game_full).
-- 2) After an organizer decision (pending → approved/rejected), emit one
--    durable FanGeo Inbox row + APNs to the requester only, via the existing
--    pickup_game_update_events → fanout → notify-pickup-game-change pipeline.
--    Self-RSVP / account-leave / deletion paths do not notify.
--
-- No table-structure change. PREPARE ONLY — do not auto-apply.
-- Edge redeploy required: notify-pickup-game-change (targeted recipient + copy).
-- =============================================================================

DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.pickup_game_requests') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.pickup_game_requests'];
  END IF;
  IF to_regclass('public.pickup_game_update_events') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.pickup_game_update_events'];
  END IF;
  IF to_regclass('public.fan_notification_inbox') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.fan_notification_inbox'];
  END IF;
  IF to_regprocedure('public.queue_pickup_game_change_push_notification(uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['queue_pickup_game_change_push_notification(uuid)'];
  END IF;
  IF to_regprocedure('public.fanout_fan_notification_inbox_for_pickup_update_event(uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['fanout_fan_notification_inbox_for_pickup_update_event(uuid)'];
  END IF;
  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION
      '20260992_0001 prerequisite missing: %',
      array_to_string(v_missing, ', ');
  END IF;
END $$;

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Allow over-capacity organizer approve (no pickup_game_full)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pickup_game_requests_before_update_status()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  is_creator boolean;
  game_removed boolean;
  v_deletion_subject_text text := nullif(btrim(current_setting('gameon.account_deletion_anonymize', true)), '');
  v_deletion_subject uuid;
  v_leave_subject_text text := nullif(btrim(current_setting('gameon.fan_team_member_leave_cleanup', true)), '');
  v_leave_subject uuid;
  v_me uuid := auth.uid();
  v_team_linked boolean;
BEGIN
  IF OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  IF v_deletion_subject_text IS NOT NULL THEN
    BEGIN
      v_deletion_subject := v_deletion_subject_text::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      v_deletion_subject := NULL;
    END;

    IF v_deletion_subject IS NOT NULL THEN
      IF NEW.status = 'withdrawn'
         AND OLD.status = 'approved'
         AND NEW.requester_user_id = v_deletion_subject THEN
        RETURN NEW;
      END IF;

      IF NEW.status = 'cancelled'
         AND OLD.status IN ('pending', 'approved', 'rejected')
         AND NEW.requester_user_id = v_deletion_subject THEN
        RETURN NEW;
      END IF;

      IF NEW.status = 'cancelled'
         AND OLD.status IN ('pending', 'approved')
         AND EXISTS (
           SELECT 1
           FROM public.pickup_games g
           WHERE g.id = NEW.pickup_game_id
             AND g.creator_user_id = v_deletion_subject
             AND g.status IN ('removed', 'expired')
         ) THEN
        RETURN NEW;
      END IF;
    END IF;
  END IF;

  IF v_leave_subject_text IS NOT NULL THEN
    BEGIN
      v_leave_subject := v_leave_subject_text::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      v_leave_subject := NULL;
    END;

    IF v_leave_subject IS NOT NULL
       AND NEW.requester_user_id = v_leave_subject THEN
      IF NEW.status = 'withdrawn' AND OLD.status = 'approved' THEN
        RETURN NEW;
      END IF;
      IF NEW.status = 'cancelled' AND OLD.status IN ('pending', 'approved', 'rejected') THEN
        RETURN NEW;
      END IF;
    END IF;
  END IF;

  IF v_me IS NOT NULL
     AND NEW.requester_user_id IS NOT DISTINCT FROM v_me
     AND NEW.status IN ('approved', 'pending', 'withdrawn')
     AND OLD.status IN ('approved', 'pending', 'withdrawn', 'cancelled', 'rejected')
  THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.fan_team_game_links l
      WHERE l.pickup_game_id = NEW.pickup_game_id
    ) INTO v_team_linked;

    IF v_team_linked
       AND public.is_pickup_game_fan_team_participant(NEW.pickup_game_id, v_me) THEN
      RETURN NEW;
    END IF;
  END IF;

  SELECT (g.creator_user_id = v_me) INTO is_creator
  FROM public.pickup_games g
  WHERE g.id = NEW.pickup_game_id;

  SELECT EXISTS (
    SELECT 1 FROM public.pickup_games g
    WHERE g.id = NEW.pickup_game_id
      AND g.status = 'removed'
  ) INTO game_removed;

  IF NEW.status = 'cancelled' THEN
    IF NEW.requester_user_id IS NOT DISTINCT FROM v_me
       AND OLD.status IN ('pending', 'approved', 'rejected') THEN
      RETURN NEW;
    ELSIF is_creator
          AND game_removed
          AND OLD.status IN ('pending', 'approved') THEN
      RETURN NEW;
    ELSE
      RAISE EXCEPTION 'pickup_request_cancel_forbidden' USING ERRCODE = 'check_violation';
    END IF;
  ELSIF NEW.status = 'withdrawn' THEN
    IF NEW.requester_user_id IS DISTINCT FROM v_me THEN
      RAISE EXCEPTION 'pickup_request_cancel_forbidden' USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status <> 'approved' THEN
      RAISE EXCEPTION 'pickup_request_cancel_forbidden' USING ERRCODE = 'check_violation';
    END IF;
  ELSIF NEW.status IN ('approved', 'rejected') THEN
    IF NOT is_creator OR OLD.status <> 'pending' THEN
      RAISE EXCEPTION 'pickup_request_decision_forbidden' USING ERRCODE = 'check_violation';
    END IF;
    -- Serialize approvals. Over-capacity is allowed — organizer confirms in UI.
    IF NEW.status = 'approved' THEN
      PERFORM 1 FROM public.pickup_games WHERE id = NEW.pickup_game_id FOR UPDATE;
    END IF;
  ELSE
    RAISE EXCEPTION 'pickup_request_status_forbidden' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.pickup_game_requests_before_update_status() IS
  'Pickup request status guard. Organizer approve/reject no longer raises pickup_game_full; '
  'over-capacity approve is confirmed in the Request Review UI. Self-RSVP + deletion/leave GUCs unchanged.';

-- -----------------------------------------------------------------------------
-- 2) Inbox fan-out: honor recipient_user_ids + join-request decision copy
-- -----------------------------------------------------------------------------
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
          'safe_destination', v_dest
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
          'change_kinds', to_jsonb(v_kinds)
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
  'Durable inbox fan-out for pickup/Team schedule events. Honors payload.recipient_user_ids '
  'when present (join-request decisions). Independent of APNs.';

-- -----------------------------------------------------------------------------
-- 3) AFTER decision → pickup_game_update_events → existing queue
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pickup_game_requests_after_decision_notify()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_event_id uuid;
  v_fingerprint text;
  v_kind text;
  v_title text;
  v_team_id uuid;
  v_team_name text;
  v_payload jsonb;
  v_deletion_subject_text text := nullif(btrim(current_setting('gameon.account_deletion_anonymize', true)), '');
  v_leave_subject_text text := nullif(btrim(current_setting('gameon.fan_team_member_leave_cleanup', true)), '');
BEGIN
  IF OLD.status IS DISTINCT FROM 'pending'
     OR NEW.status NOT IN ('approved', 'rejected') THEN
    RETURN NEW;
  END IF;

  -- Self-RSVP / the requester acting on their own row is not an organizer decision.
  IF NEW.requester_user_id IS NOT DISTINCT FROM auth.uid() THEN
    RETURN NEW;
  END IF;
  IF v_deletion_subject_text IS NOT NULL OR v_leave_subject_text IS NOT NULL THEN
    RETURN NEW;
  END IF;
  IF NEW.requester_user_id IS NULL THEN
    RETURN NEW;
  END IF;

  v_kind := CASE
    WHEN NEW.status = 'approved' THEN 'join_request_approved'
    ELSE 'join_request_rejected'
  END;
  v_fingerprint := 'join_request_decision:' || lower(NEW.id::text) || ':' || NEW.status;

  SELECT nullif(btrim(g.title), '') INTO v_title
  FROM public.pickup_games g
  WHERE g.id = NEW.pickup_game_id;
  v_title := coalesce(v_title, 'Event');

  SELECT l.team_id, nullif(btrim(t.name), '')
  INTO v_team_id, v_team_name
  FROM public.fan_team_game_links l
  INNER JOIN public.fan_teams t ON t.id = l.team_id AND t.is_active = true
  WHERE l.pickup_game_id = NEW.pickup_game_id
  LIMIT 1;

  v_payload := jsonb_build_object(
    'notification_type', v_kind,
    'title', v_title,
    'recipient_user_ids', jsonb_build_array(NEW.requester_user_id),
    'request_id', NEW.id,
    'pickup_game_id', NEW.pickup_game_id,
    'team_id', v_team_id,
    'team_name', coalesce(v_team_name, ''),
    'safe_destination', 'scheduleActivity'
  );

  INSERT INTO public.pickup_game_update_events (
    pickup_game_id,
    editor_user_id,
    fingerprint,
    change_kinds,
    payload,
    push_delivery_status
  )
  VALUES (
    NEW.pickup_game_id,
    auth.uid(),
    v_fingerprint,
    ARRAY['join_request_decision']::text[],
    v_payload,
    'pending'
  )
  ON CONFLICT (pickup_game_id, fingerprint) DO UPDATE
    SET payload = EXCLUDED.payload
  RETURNING id INTO v_event_id;

  IF v_event_id IS NOT NULL THEN
    BEGIN
      PERFORM public.queue_pickup_game_change_push_notification(v_event_id);
    EXCEPTION WHEN OTHERS THEN
      RAISE LOG
        '[PickupJoinDecision] queueFailed request=% event=% err=%',
        NEW.id, v_event_id, SQLERRM;
    END;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS pickup_game_requests_after_decision_notify_au
  ON public.pickup_game_requests;
CREATE TRIGGER pickup_game_requests_after_decision_notify_au
  AFTER UPDATE OF status ON public.pickup_game_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.pickup_game_requests_after_decision_notify();

COMMENT ON FUNCTION public.pickup_game_requests_after_decision_notify() IS
  'After organizer approve/reject: enqueue pickup_game_update_events for the requester only '
  '(inbox + notify-pickup-game-change). Skips self-RSVP and trusted cleanup GUCs.';

REVOKE ALL ON FUNCTION public.pickup_game_requests_after_decision_notify() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pickup_game_requests_after_decision_notify() FROM anon;
REVOKE ALL ON FUNCTION public.pickup_game_requests_after_decision_notify() FROM authenticated;

-- -----------------------------------------------------------------------------
-- 4) Structural verification
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_before text;
  v_after text;
  v_fanout text;
BEGIN
  SELECT p.prosrc INTO v_before
  FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.pickup_game_requests_before_update_status()'::regprocedure;
  IF position('pickup_game_full' IN v_before) > 0 THEN
    RAISE EXCEPTION '20260992 before-update still raises pickup_game_full';
  END IF;

  SELECT p.prosrc INTO v_after
  FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.pickup_game_requests_after_decision_notify()'::regprocedure;
  IF position('join_request_approved' IN v_after) = 0
     OR position('recipient_user_ids' IN v_after) = 0 THEN
    RAISE EXCEPTION '20260992 after-decision notify missing join-request emit';
  END IF;

  SELECT p.prosrc INTO v_fanout
  FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.fanout_fan_notification_inbox_for_pickup_update_event(uuid)'::regprocedure;
  IF position('join_request_approved' IN v_fanout) = 0
     OR position('recipient_user_ids' IN v_fanout) = 0 THEN
    RAISE EXCEPTION '20260992 fanout missing join-request targeting';
  END IF;

  RAISE NOTICE '[20260992] over-capacity approve + join-decision inbox verified';
END $$;

COMMIT;
