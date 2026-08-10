-- Fan Team owner soft-delete (Delete Team).
--
-- Do NOT apply from the agent. Apply manually after 20260926–20260932.
--
-- Strategy:
--   • Soft-deactivate fan_teams.is_active = false (same flag as admin_set_fan_team_active)
--   • Soft-leave ALL active roster members (incl. owner) + Team Chat memberships
--   • Cancel pending invitations silently (no deletion push to invitees)
--   • Preserve chat messages, conversation row, pickup_games, fan_team_game_links,
--     reports, and membership history rows
--   • Notify other active members via queue + ledger + Edge notify-fan-team-deleted
--
-- Admin moderation deactivate (admin_set_fan_team_active) remains SEPARATE and does
-- NOT send owner-driven "Team deleted" member pushes.

-- ---------------------------------------------------------------------------
-- 1) Deletion event + per-recipient push ledger
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.fan_team_deletion_events (
  id uuid PRIMARY KEY,
  team_id uuid NOT NULL REFERENCES public.fan_teams (id) ON DELETE CASCADE,
  owner_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  team_name text NOT NULL,
  recipient_user_ids uuid[] NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS fan_team_deletion_events_team_created_idx
  ON public.fan_team_deletion_events (team_id, created_at DESC);

COMMENT ON TABLE public.fan_team_deletion_events IS
  'Owner Delete Team events. recipient_user_ids captured BEFORE soft-leave for trusted push fan-out.';

ALTER TABLE public.fan_team_deletion_events ENABLE ROW LEVEL SECURITY;
GRANT ALL ON public.fan_team_deletion_events TO service_role;

CREATE TABLE IF NOT EXISTS public.fan_team_deleted_push_deliveries (
  event_id uuid NOT NULL REFERENCES public.fan_team_deletion_events (id) ON DELETE CASCADE,
  recipient_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  team_id uuid NOT NULL,
  delivery_status text NOT NULL DEFAULT 'queued'
    CHECK (delivery_status IN ('queued', 'sent', 'skipped', 'failed')),
  skip_reason text,
  sent_token_count integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (event_id, recipient_user_id)
);

CREATE INDEX IF NOT EXISTS fan_team_deleted_push_deliveries_team_created_idx
  ON public.fan_team_deleted_push_deliveries (team_id, created_at DESC);

ALTER TABLE public.fan_team_deleted_push_deliveries ENABLE ROW LEVEL SECURITY;
GRANT ALL ON public.fan_team_deleted_push_deliveries TO service_role;

-- ---------------------------------------------------------------------------
-- 2) Queue Edge fan-out (service_role / SECURITY DEFINER callers only)
-- ---------------------------------------------------------------------------
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
BEGIN
  IF p_event_id IS NULL THEN
    RETURN;
  END IF;

  IF to_regnamespace('net') IS NULL OR to_regclass('vault.decrypted_secrets') IS NULL THEN
    RAISE NOTICE 'fan team deleted push skipped: pg_net or vault unavailable';
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
    RAISE NOTICE 'fan team deleted push skipped: vault secrets missing';
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

  PERFORM net.http_post(
    url := v_url || '/functions/v1/notify-fan-team-deleted',
    headers := v_headers,
    body := jsonb_build_object('event_id', p_event_id),
    timeout_milliseconds := 15000
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'fan team deleted push queue failed: %', SQLERRM;
END;
$$;

REVOKE ALL ON FUNCTION public.queue_fan_team_deleted_push_notification(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.queue_fan_team_deleted_push_notification(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.queue_fan_team_deleted_push_notification(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.queue_fan_team_deleted_push_notification(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3) Rate-limit allowlist (+ delete_fan_team)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_rpc_rate_limit(
  p_bucket text,
  p_max int,
  p_window_seconds int
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_bucket text := nullif(btrim(coalesce(p_bucket, '')), '');
  v_window_start timestamptz;
  v_count int;
  v_allowed_buckets text[] := ARRAY[
    'send_direct_message',
    'send_group_message',
    'friendship_ensure_pending',
    'poke_profile',
    'report_group_message',
    'search_chat_conversations',
    'search_chat_messages',
    'create_fan_team',
    'invite_fan_team_members',
    'accept_fan_team_invitation',
    'decline_fan_team_invitation',
    'report_fan_team',
    'leave_fan_team',
    'delete_fan_team'
  ];
BEGIN
  IF coalesce(auth.role(), '') = 'service_role' AND me IS NULL THEN
    RETURN;
  END IF;

  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  IF v_bucket IS NULL OR NOT (v_bucket = ANY (v_allowed_buckets)) THEN
    RAISE EXCEPTION 'rate limit rejected' USING ERRCODE = '22023';
  END IF;

  IF p_max IS NULL OR p_max < 1 OR p_max > 100000 THEN
    RAISE EXCEPTION 'rate limit rejected' USING ERRCODE = '22023';
  END IF;

  IF p_window_seconds IS NULL OR p_window_seconds < 1 OR p_window_seconds > 86400 THEN
    RAISE EXCEPTION 'rate limit rejected' USING ERRCODE = '22023';
  END IF;

  v_window_start := to_timestamp(
    floor(extract(epoch FROM now()) / p_window_seconds::double precision)
      * p_window_seconds::double precision
  );

  INSERT INTO public.rpc_rate_limits AS r (actor_uid, bucket, window_start, count)
  VALUES (me, v_bucket, v_window_start, 1)
  ON CONFLICT (actor_uid, bucket, window_start)
  DO UPDATE SET count = LEAST(r.count + 1, 1000000)
  RETURNING r.count INTO v_count;

  IF v_count > p_max THEN
    RAISE EXCEPTION 'rate_limit_exceeded'
      USING ERRCODE = '54000';
  END IF;

  IF (random() < 0.01) THEN
    DELETE FROM public.rpc_rate_limits
    WHERE window_start < (now() - interval '7 days');
  END IF;
END;
$$;

COMMENT ON FUNCTION public.assert_rpc_rate_limit(text, int, int) IS
  'SECURITY DEFINER fixed-window rate limit with allowlisted buckets (includes Fan Team delete). Not granted to authenticated clients.';

REVOKE ALL ON FUNCTION public.assert_rpc_rate_limit(text, int, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.assert_rpc_rate_limit(text, int, int) FROM anon;
REVOKE ALL ON FUNCTION public.assert_rpc_rate_limit(text, int, int) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.assert_rpc_rate_limit(text, int, int) TO service_role;

-- ---------------------------------------------------------------------------
-- 4) delete_fan_team — owner-only soft delete
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.delete_fan_team(p_team_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_owner uuid;
  v_name text;
  v_active boolean;
  v_conversation_id uuid;
  v_event_id uuid := gen_random_uuid();
  v_recipients uuid[];
  v_existing_event uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  PERFORM public.assert_rpc_rate_limit('delete_fan_team', 10, 3600);

  IF p_team_id IS NULL THEN
    RAISE EXCEPTION 'Team id is required.';
  END IF;

  SELECT t.owner_user_id, t.name, t.is_active, t.group_conversation_id
  INTO v_owner, v_name, v_active, v_conversation_id
  FROM public.fan_teams t
  WHERE t.id = p_team_id
  FOR UPDATE;

  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  IF v_owner <> me THEN
    RAISE EXCEPTION 'Only the Team owner can delete this Team.';
  END IF;

  -- Idempotent owner-delete: return existing deletion EVENT id only.
  -- Admin moderation deactivate (no fan_team_deletion_events row) must not
  -- return p_team_id as though it were an event id.
  IF v_active IS NOT TRUE THEN
    SELECT e.id INTO v_existing_event
    FROM public.fan_team_deletion_events e
    WHERE e.team_id = p_team_id
    ORDER BY e.created_at DESC
    LIMIT 1;

    IF v_existing_event IS NOT NULL THEN
      RETURN v_existing_event;
    END IF;

    RAISE EXCEPTION 'Team is already inactive.';
  END IF;

  -- Snapshot recipients BEFORE soft-leave (exclude deleting owner).
  SELECT coalesce(array_agg(m.user_id ORDER BY m.user_id), '{}'::uuid[])
  INTO v_recipients
  FROM public.fan_team_members m
  WHERE m.team_id = p_team_id
    AND m.left_at IS NULL
    AND m.user_id <> me;

  -- 1) Deactivate Team
  UPDATE public.fan_teams
  SET is_active = false, updated_at = now()
  WHERE id = p_team_id;

  -- 2) Cancel pending invitations (silent — no deletion push to invitees)
  UPDATE public.fan_team_invitations
  SET status = 'cancelled',
      cancelled_at = now(),
      responded_at = coalesce(responded_at, now())
  WHERE team_id = p_team_id
    AND status = 'pending';

  -- 3) Soft-leave every active Team member (including owner)
  UPDATE public.fan_team_members
  SET left_at = now()
  WHERE team_id = p_team_id
    AND left_at IS NULL;

  -- 4) Soft-leave linked Team Chat members
  IF v_conversation_id IS NOT NULL THEN
    UPDATE public.group_conversation_members
    SET left_at = now()
    WHERE conversation_id = v_conversation_id
      AND left_at IS NULL;
  END IF;

  -- 5) Lifecycle event for audit + push fan-out
  INSERT INTO public.fan_team_deletion_events (
    id, team_id, owner_user_id, team_name, recipient_user_ids
  ) VALUES (
    v_event_id, p_team_id, me, coalesce(nullif(btrim(v_name), ''), 'Team'), v_recipients
  );

  -- Optional audit trail (not admin_audit_logs — those are service_role moderation).
  -- Kept on fan_team_deletion_events as the owner lifecycle record.

  -- 6) Queue member notifications (best-effort; deletion already committed above)
  IF cardinality(v_recipients) > 0 THEN
    PERFORM public.queue_fan_team_deleted_push_notification(v_event_id);
  END IF;

  RETURN v_event_id;
END;
$$;

COMMENT ON FUNCTION public.delete_fan_team(uuid) IS
  'Owner-only soft-delete: is_active=false, cancel invites, soft-leave roster+Team Chat, queue member pushes. Preserves history. '
  'Returns fan_team_deletion_events.id. Idempotent when an owner deletion event exists; raises if Team is inactive without one.';

REVOKE ALL ON FUNCTION public.delete_fan_team(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_fan_team(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.delete_fan_team(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_fan_team(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- Manual apply notes
-- ---------------------------------------------------------------------------
-- After prior Team migrations:
--   20260933_0001_delete_fan_team.sql
--
-- Then:
--   supabase functions deploy notify-fan-team-deleted --no-verify-jwt
--
-- Checks:
--   SELECT has_function_privilege('authenticated','public.delete_fan_team(uuid)','EXECUTE');
--   SELECT has_function_privilege('authenticated','public.queue_fan_team_deleted_push_notification(uuid)','EXECUTE'); -- false
--   SELECT prosrc LIKE '%delete_fan_team%' FROM pg_proc WHERE proname = 'assert_rpc_rate_limit';
