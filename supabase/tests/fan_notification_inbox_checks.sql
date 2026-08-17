-- =============================================================================
-- fan_notification_inbox checks (run after applying 20260983)
-- =============================================================================

DO $$
BEGIN
  IF to_regclass('public.fan_notification_inbox') IS NULL THEN
    RAISE EXCEPTION 'fan_notification_inbox missing — apply 20260983_0001 first';
  END IF;
  IF to_regprocedure('public.fanout_fan_notification_inbox_for_pickup_update_event(uuid)') IS NULL THEN
    RAISE EXCEPTION 'fanout_fan_notification_inbox_for_pickup_update_event missing';
  END IF;
  IF to_regprocedure('public.list_my_fan_notification_inbox(integer,timestamptz,uuid)') IS NULL THEN
    RAISE EXCEPTION 'list_my_fan_notification_inbox missing';
  END IF;
END $$;

-- Idempotent upsert: same dedupe key must not create duplicates.
DO $$
DECLARE
  v_user uuid := '00000000-0000-4000-8000-000000000001';
  v_id1 uuid;
  v_id2 uuid;
  v_count integer;
BEGIN
  -- Skip if auth.users row unavailable in this environment.
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = v_user) THEN
    RAISE NOTICE 'skip upsert self-test: fixture user missing';
    RETURN;
  END IF;

  v_id1 := public.upsert_fan_notification_inbox(
    p_user_id := v_user,
    p_notification_type := 'time_changed',
    p_title := 'Team updated the time',
    p_body := 'Practice',
    p_kind_raw := 'scheduleChange',
    p_destination_raw := 'scheduleActivity',
    p_deduplication_key := 'pickup_update:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    p_source_type := 'pickup_game_change_notification',
    p_payload := '{}'::jsonb
  );
  v_id2 := public.upsert_fan_notification_inbox(
    p_user_id := v_user,
    p_notification_type := 'time_changed',
    p_title := 'Team updated the time',
    p_body := 'Practice',
    p_kind_raw := 'scheduleChange',
    p_destination_raw := 'scheduleActivity',
    p_deduplication_key := 'pickup_update:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    p_source_type := 'pickup_game_change_notification',
    p_payload := '{}'::jsonb
  );
  IF v_id1 IS DISTINCT FROM v_id2 THEN
    RAISE EXCEPTION 'dedupe failed: % vs %', v_id1, v_id2;
  END IF;
  SELECT count(*) INTO v_count
  FROM public.fan_notification_inbox
  WHERE user_id = v_user
    AND deduplication_key =
      'pickup_update:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'expected 1 row, got %', v_count;
  END IF;
  RAISE NOTICE 'PASS dedupe upsert';
END $$;

SELECT 'fan_notification_inbox_checks_ok' AS status;
