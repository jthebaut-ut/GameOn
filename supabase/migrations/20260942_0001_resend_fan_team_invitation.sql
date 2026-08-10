-- =============================================================================
-- 20260942_0001 — Fan Team invitation push: diagnostics + resend
-- =============================================================================
-- Production-readiness audit (pre-apply):
--   • Official pg_net docs: HTTP requests are NOT started until COMMIT.
--     Enqueue via net.http_post is transactional; Edge cannot see a committed
--     invitation row "too early" from the inviting TX. Commit-race theory for
--     invitation_not_found is UNLIKELY / UNPROVEN against this architecture.
--   • create_fan_team / add_fan_team_members use the same invitation helper +
--     queue helper (kind=create|invite). Deferred queue is for kind tagging /
--     explicit event_ids — NOT a commit-race fix (still same TX).
--   • Working push systems (friend request, chat, poke, team delete, pickup
--     change) use the same in-TX net.http_post pattern.
--
-- This migration:
--   1) Persist kind + pg_net_request_id on fan_team_invitation_push_deliveries
--      at queue time (status=queued) so invitation → pg_net → Edge correlates.
--   2) create/invite: insert with p_queue_push=false then explicit queue
--      (kind=create|invite); one invitation row each; no duplicates.
--   3) resend_fan_team_invitation: manager-only; same invitation_id; new
--      event_id; 5-min cooldown on ANY delivery ledger row for that invitation
--      (queued/sent/skipped/failed = an attempt was recorded); 20/hour actor.
--
-- Do NOT apply from the agent. Apply manually after 20260941.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 0) Delivery ledger — correlation columns (smallest observability)
-- ---------------------------------------------------------------------------
ALTER TABLE public.fan_team_invitation_push_deliveries
  ADD COLUMN IF NOT EXISTS kind text,
  ADD COLUMN IF NOT EXISTS pg_net_request_id bigint;

COMMENT ON COLUMN public.fan_team_invitation_push_deliveries.kind IS
  'Queue kind: invite | create | resend (diagnostic only).';
COMMENT ON COLUMN public.fan_team_invitation_push_deliveries.pg_net_request_id IS
  'net.http_post request id; join to net._http_response.id (retained ~6h).';

-- ---------------------------------------------------------------------------
-- 1) Rate-limit allowlist (+ resend bucket)
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
    'delete_fan_team',
    'resend_fan_team_invitation'
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

REVOKE ALL ON FUNCTION public.assert_rpc_rate_limit(text, int, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.assert_rpc_rate_limit(text, int, int) FROM anon;
REVOKE ALL ON FUNCTION public.assert_rpc_rate_limit(text, int, int) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.assert_rpc_rate_limit(text, int, int) TO service_role;

-- ---------------------------------------------------------------------------
-- 2) Queue helper — persist ledger + pg_net request_id; optional kind
-- ---------------------------------------------------------------------------
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

  SELECT decrypted_secret
  INTO v_service_role_key
  FROM vault.decrypted_secrets
  WHERE name IN ('SUPABASE_SERVICE_ROLE_KEY', 'fangeo_service_role_key')
    AND NULLIF(btrim(decrypted_secret), '') IS NOT NULL
  ORDER BY CASE name WHEN 'SUPABASE_SERVICE_ROLE_KEY' THEN 0 ELSE 1 END
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

  v_headers := jsonb_build_object(
    'Content-Type', 'application/json',
    'Authorization', 'Bearer ' || v_service_role_key
  );

  IF v_cron_secret IS NOT NULL THEN
    v_headers := v_headers || jsonb_build_object('x-cron-secret', v_cron_secret);
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

-- ---------------------------------------------------------------------------
-- 3) create_fan_team — insert invites then queue pushes (same helper as Invite)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_fan_team(
  p_name text,
  p_sport text DEFAULT '',
  p_member_ids uuid[] DEFAULT ARRAY[]::uuid[],
  p_color_hex text DEFAULT NULL,
  p_logo_url text DEFAULT NULL,
  p_logo_thumbnail_url text DEFAULT NULL,
  p_competition_level text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_name text := btrim(coalesce(p_name, ''));
  v_sport text := btrim(coalesce(p_sport, ''));
  v_ids uuid[];
  v_unique uuid[] := ARRAY[]::uuid[];
  v_uid uuid;
  v_conversation_id uuid;
  v_team_id uuid;
  v_payload jsonb;
  v_color text := nullif(btrim(coalesce(p_color_hex, '')), '');
  v_level text := public.fan_team_normalize_competition_level(p_competition_level);
  v_invitation_id uuid;
  v_invitation_ids uuid[] := ARRAY[]::uuid[];
  v_event_id uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  PERFORM public.assert_rpc_rate_limit('create_fan_team', 20, 3600);

  IF char_length(v_name) < 1 OR char_length(v_name) > 60 THEN
    RAISE EXCEPTION 'Team name must be between 1 and 60 characters.';
  END IF;

  IF char_length(v_sport) > 40 THEN
    RAISE EXCEPTION 'Sport label is too long.';
  END IF;

  IF v_color IS NOT NULL AND v_color !~* '^#?[0-9A-Fa-f]{6}$' THEN
    RAISE EXCEPTION 'Invalid team color.';
  END IF;
  IF v_color IS NOT NULL AND left(v_color, 1) <> '#' THEN
    v_color := '#' || v_color;
  END IF;

  v_ids := coalesce(p_member_ids, ARRAY[]::uuid[]);
  FOREACH v_uid IN ARRAY v_ids LOOP
    IF v_uid IS NULL OR v_uid = me THEN
      CONTINUE;
    END IF;
    IF NOT (v_uid = ANY (v_unique)) THEN
      v_unique := array_append(v_unique, v_uid);
    END IF;
  END LOOP;

  IF 1 + coalesce(array_length(v_unique, 1), 0) > 50 THEN
    RAISE EXCEPTION 'A team may have at most 50 members.';
  END IF;

  FOREACH v_uid IN ARRAY v_unique LOOP
    IF NOT public.group_add_member_eligible(me, v_uid) THEN
      RAISE EXCEPTION 'One or more invitees are not eligible.';
    END IF;
  END LOOP;

  INSERT INTO public.group_conversations (title, created_by)
  VALUES (v_name, me)
  RETURNING id INTO v_conversation_id;

  INSERT INTO public.group_conversation_members (
    conversation_id, user_id, role, joined_at, last_read_at
  ) VALUES (
    v_conversation_id, me, 'admin', now(), now()
  );

  v_payload := jsonb_build_object(
    'event', 'group_created',
    'actor_user_id', me,
    'fan_team', true
  );

  INSERT INTO public.group_messages (
    conversation_id, sender_id, body, message_type, system_event, system_payload
  ) VALUES (
    v_conversation_id, me, 'Team created', 'system', 'group_created', v_payload
  );

  UPDATE public.group_conversations
  SET
    last_message_at = now(),
    last_message_preview = 'Team created',
    last_message_sender_id = me,
    last_message_type = 'system',
    last_system_event = 'group_created',
    last_system_payload = v_payload,
    updated_at = now()
  WHERE id = v_conversation_id;

  IF nullif(btrim(coalesce(p_logo_url, '')), '') IS NOT NULL
     OR nullif(btrim(coalesce(p_logo_thumbnail_url, '')), '') IS NOT NULL THEN
    RAISE NOTICE 'create_fan_team ignored logo URL args; use update_fan_team_identity after upload';
  END IF;

  INSERT INTO public.fan_teams (
    name,
    sport,
    logo_url,
    logo_thumbnail_url,
    color_hex,
    competition_level,
    owner_user_id,
    group_conversation_id
  ) VALUES (
    v_name,
    v_sport,
    NULL,
    NULL,
    v_color,
    v_level,
    me,
    v_conversation_id
  )
  RETURNING id INTO v_team_id;

  INSERT INTO public.fan_team_members (team_id, user_id, role)
  VALUES (v_team_id, me, 'owner');

  -- Same invitation helper as Invite Members; queue after inserts (kind=create).
  FOREACH v_uid IN ARRAY v_unique LOOP
    v_invitation_id := public.fan_team_insert_pending_invitation(v_team_id, me, v_uid, false);
    IF v_invitation_id IS NOT NULL THEN
      v_invitation_ids := array_append(v_invitation_ids, v_invitation_id);
    END IF;
  END LOOP;

  FOREACH v_invitation_id IN ARRAY v_invitation_ids LOOP
    v_event_id := gen_random_uuid();
    PERFORM public.queue_fan_team_invitation_push_notification(
      v_invitation_id,
      v_event_id,
      'create'
    );
  END LOOP;

  RETURN v_team_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_fan_team(text, text, uuid[], text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_fan_team(text, text, uuid[], text, text, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.create_fan_team(text, text, uuid[], text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_fan_team(text, text, uuid[], text, text, text, text) TO service_role;

COMMENT ON FUNCTION public.create_fan_team(text, text, uuid[], text, text, text, text) IS
  'Create Fan Team + linked chat. Selected p_member_ids become pending invitations '
  '(fan_team_insert_pending_invitation) then each gets one invitation push via '
  'queue_fan_team_invitation_push_notification(kind=create). Never auto-joins invitees.';

-- ---------------------------------------------------------------------------
-- 3b) add_fan_team_members — same insert helper + deferred explicit queue
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.add_fan_team_members(
  p_team_id uuid,
  p_member_ids uuid[]
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_uid uuid;
  v_unique uuid[] := ARRAY[]::uuid[];
  v_new uuid[] := ARRAY[]::uuid[];
  v_invited integer := 0;
  v_active integer;
  v_pending integer;
  v_id uuid;
  v_invitation_ids uuid[] := ARRAY[]::uuid[];
  v_event_id uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  PERFORM public.assert_rpc_rate_limit('invite_fan_team_members', 40, 3600);

  IF NOT public.fan_team_viewer_can_manage(p_team_id) THEN
    RAISE EXCEPTION 'Only the owner or a manager can invite members.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.fan_teams t
    WHERE t.id = p_team_id AND t.is_active = true
  ) THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  FOREACH v_uid IN ARRAY coalesce(p_member_ids, ARRAY[]::uuid[]) LOOP
    IF v_uid IS NULL OR v_uid = me THEN
      CONTINUE;
    END IF;
    IF NOT (v_uid = ANY (v_unique)) THEN
      v_unique := array_append(v_unique, v_uid);
    END IF;
  END LOOP;

  IF coalesce(array_length(v_unique, 1), 0) = 0 THEN
    RETURN 0;
  END IF;

  UPDATE public.fan_team_invitations
  SET status = 'expired', responded_at = coalesce(responded_at, now())
  WHERE team_id = p_team_id
    AND status = 'pending'
    AND expires_at IS NOT NULL
    AND expires_at <= now();

  SELECT count(*)::integer INTO v_active
  FROM public.fan_team_members
  WHERE team_id = p_team_id AND left_at IS NULL;

  SELECT count(*)::integer INTO v_pending
  FROM public.fan_team_invitations i
  WHERE i.team_id = p_team_id
    AND i.status = 'pending'
    AND (i.expires_at IS NULL OR i.expires_at > now());

  FOREACH v_uid IN ARRAY v_unique LOOP
    IF public.is_active_fan_team_member(p_team_id, v_uid) THEN
      CONTINUE;
    END IF;
    IF EXISTS (
      SELECT 1
      FROM public.fan_team_invitations i
      WHERE i.team_id = p_team_id
        AND i.invitee_user_id = v_uid
        AND i.status = 'pending'
        AND (i.expires_at IS NULL OR i.expires_at > now())
    ) THEN
      CONTINUE;
    END IF;
    IF NOT public.group_add_member_eligible(me, v_uid) THEN
      CONTINUE;
    END IF;
    v_new := array_append(v_new, v_uid);
  END LOOP;

  IF coalesce(array_length(v_new, 1), 0) = 0 THEN
    RETURN 0;
  END IF;

  IF v_active + v_pending + coalesce(array_length(v_new, 1), 0) > 50 THEN
    RAISE EXCEPTION 'A team may have at most 50 members (including pending invitations).';
  END IF;

  FOREACH v_uid IN ARRAY v_new LOOP
    v_id := public.fan_team_insert_pending_invitation(p_team_id, me, v_uid, false);
    IF v_id IS NOT NULL THEN
      v_invitation_ids := array_append(v_invitation_ids, v_id);
      v_invited := v_invited + 1;
    END IF;
  END LOOP;

  FOREACH v_id IN ARRAY v_invitation_ids LOOP
    v_event_id := gen_random_uuid();
    PERFORM public.queue_fan_team_invitation_push_notification(v_id, v_event_id, 'invite');
  END LOOP;

  RETURN v_invited;
END;
$$;

REVOKE ALL ON FUNCTION public.add_fan_team_members(uuid, uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.add_fan_team_members(uuid, uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.add_fan_team_members(uuid, uuid[]) TO service_role;

COMMENT ON FUNCTION public.add_fan_team_members(uuid, uuid[]) IS
  'Owner/manager Team invites via fan_team_insert_pending_invitation + one push event each '
  '(kind=invite). Does not auto-join. Same invitation system as create_fan_team.';

-- ---------------------------------------------------------------------------
-- 4) resend_fan_team_invitation — same invitation_id, new event_id
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.resend_fan_team_invitation(p_invitation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_inv public.fan_team_invitations%ROWTYPE;
  v_event_id uuid;
  v_recent boolean := false;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.' USING ERRCODE = '42501';
  END IF;

  IF p_invitation_id IS NULL THEN
    RAISE EXCEPTION 'Invitation not found.' USING ERRCODE = 'P0002';
  END IF;

  -- Actor hourly cap (spam prevention).
  PERFORM public.assert_rpc_rate_limit('resend_fan_team_invitation', 20, 3600);

  SELECT * INTO v_inv
  FROM public.fan_team_invitations
  WHERE id = p_invitation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invitation not found.' USING ERRCODE = 'P0002';
  END IF;

  IF NOT public.fan_team_viewer_can_manage(v_inv.team_id) THEN
    RAISE EXCEPTION 'Only the owner or a manager can resend invitations.' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.fan_teams t
    WHERE t.id = v_inv.team_id AND t.is_active = true
  ) THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  IF v_inv.status <> 'pending' THEN
    RAISE EXCEPTION 'Invitation is no longer pending.';
  END IF;

  IF v_inv.expires_at IS NOT NULL AND v_inv.expires_at <= now() THEN
    UPDATE public.fan_team_invitations
    SET status = 'expired', responded_at = coalesce(responded_at, now())
    WHERE id = v_inv.id AND status = 'pending';
    RAISE EXCEPTION 'Invitation has expired.';
  END IF;

  -- Per-invitation 5-minute cooldown: ANY ledger row (queued/sent/skipped/failed)
  -- created in the last 5 minutes counts as an attempt. After 20260942, queue
  -- always writes a ledger row when secrets/pg_net allow or when they fail.
  SELECT EXISTS (
    SELECT 1
    FROM public.fan_team_invitation_push_deliveries d
    WHERE d.invitation_id = v_inv.id
      AND d.created_at > now() - interval '5 minutes'
  ) INTO v_recent;

  IF v_recent THEN
    RETURN jsonb_build_object(
      'ok', false,
      'rate_limited', true,
      'invitation_id', v_inv.id,
      'message', 'Invitation was recently sent. Please wait a few minutes before resending.'
    );
  END IF;

  v_event_id := gen_random_uuid();
  PERFORM public.queue_fan_team_invitation_push_notification(
    v_inv.id,
    v_event_id,
    'resend'
  );

  RETURN jsonb_build_object(
    'ok', true,
    'rate_limited', false,
    'invitation_id', v_inv.id,
    'event_id', v_event_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.resend_fan_team_invitation(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.resend_fan_team_invitation(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.resend_fan_team_invitation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.resend_fan_team_invitation(uuid) TO service_role;

COMMENT ON FUNCTION public.resend_fan_team_invitation(uuid) IS
  'Owner/manager resend of a still-pending Fan Team invitation push. Does not insert '
  'another invitation row. Queues a new event_id for the same invitation_id. '
  '5-minute per-invitation cooldown (any delivery ledger row) + 20/hour actor rate limit.';

COMMIT;

-- Manual verification (do not run from agent):
--   SELECT proname FROM pg_proc WHERE proname = 'resend_fan_team_invitation';
--   SELECT event_id, invitation_id, delivery_status, skip_reason, kind, pg_net_request_id, created_at
--   FROM fan_team_invitation_push_deliveries ORDER BY created_at DESC LIMIT 20;
-- Deploy order (manual — critical):
--   1) Deploy Edge FIRST (handles pre-queued ledger rows; safe before columns exist):
--        supabase functions deploy notify-fan-team-invitation --no-verify-jwt
--   2) Then apply this migration (queue starts pre-inserting + storing request_id).
--   Do NOT leave migration applied with the old Edge: old claim treated 23505 as
--   already_claimed and would skip APNs after pre-insert.
