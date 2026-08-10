-- =============================================================================
-- 20260929_0001 — Fan Team invitation-based membership
-- =============================================================================
-- Changes create_fan_team / add_fan_team_members from immediate membership to
-- PENDING invitations. Acceptance atomically joins fan_team_members + Team Chat.
--
-- Backward compatible:
--   • Existing active fan_team_members remain active (not converted to invites)
--   • Existing Team Chats / games untouched
--
-- Production-preservation notes (must not regress 20260927 / 20260928):
--   • assert_rpc_rate_limit keeps full production semantics (incl. 1% 7-day
--     cleanup) and remains NOT granted to authenticated clients; only extends
--     the allowlist with Team invitation buckets (+ preserves create_fan_team).
--   • create_fan_team ignores p_logo_url / p_logo_thumbnail_url so create cannot
--     bypass hardened fan-team-logos/{team_id}/... rules from update_fan_team_identity.
--     Logo upload path: create Team → get team_id → storage upload → update identity.
--
-- Push: friend-request pattern (queue + ledger + Edge notify-fan-team-invitation)
--
-- Do NOT apply from the agent; review and apply deliberately in Supabase.
-- Apply AFTER 20260926 (and preferably 20260927–20260928).
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Preferences + invitation table
-- ---------------------------------------------------------------------------
ALTER TABLE public.user_notification_preferences
  ADD COLUMN IF NOT EXISTS fan_team_invitation_notifications_enabled boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.user_notification_preferences.fan_team_invitation_notifications_enabled IS
  'When false, user must not receive Fan Team invitation APNs. Defaults to true.';

CREATE TABLE IF NOT EXISTS public.fan_team_invitations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id uuid NOT NULL REFERENCES public.fan_teams (id) ON DELETE CASCADE,
  inviter_user_id uuid NOT NULL REFERENCES auth.users (id),
  invitee_user_id uuid NOT NULL REFERENCES auth.users (id),
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'accepted', 'declined', 'cancelled', 'expired')),
  created_at timestamptz NOT NULL DEFAULT now(),
  responded_at timestamptz,
  cancelled_at timestamptz,
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '30 days'),
  CHECK (inviter_user_id <> invitee_user_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS fan_team_invitations_unique_pending_idx
  ON public.fan_team_invitations (team_id, invitee_user_id)
  WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS fan_team_invitations_invitee_pending_idx
  ON public.fan_team_invitations (invitee_user_id, created_at DESC)
  WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS fan_team_invitations_team_pending_idx
  ON public.fan_team_invitations (team_id, created_at DESC)
  WHERE status = 'pending';

COMMENT ON TABLE public.fan_team_invitations IS
  'Pending Fan Team membership invitations. Active membership is only created on accept.';

ALTER TABLE public.fan_team_invitations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "fan_team_invitations_select_own_or_manage" ON public.fan_team_invitations;
CREATE POLICY "fan_team_invitations_select_own_or_manage"
  ON public.fan_team_invitations FOR SELECT
  TO authenticated
  USING (
    invitee_user_id = auth.uid()
    OR public.fan_team_viewer_can_manage(team_id)
  );

REVOKE ALL ON public.fan_team_invitations FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE ON public.fan_team_invitations FROM authenticated;
GRANT SELECT ON public.fan_team_invitations TO authenticated;
GRANT ALL ON public.fan_team_invitations TO service_role;

-- ---------------------------------------------------------------------------
-- 2) Push dedupe ledger + queue
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.fan_team_invitation_push_deliveries (
  event_id uuid NOT NULL PRIMARY KEY,
  invitation_id uuid NOT NULL REFERENCES public.fan_team_invitations (id) ON DELETE CASCADE,
  recipient_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  inviter_user_id uuid NOT NULL,
  team_id uuid NOT NULL,
  delivery_status text NOT NULL DEFAULT 'queued'
    CHECK (delivery_status IN ('queued', 'sent', 'skipped', 'failed')),
  skip_reason text,
  sent_token_count integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS fan_team_invitation_push_deliveries_invitation_created_idx
  ON public.fan_team_invitation_push_deliveries (invitation_id, created_at DESC);

ALTER TABLE public.fan_team_invitation_push_deliveries ENABLE ROW LEVEL SECURITY;
GRANT ALL ON public.fan_team_invitation_push_deliveries TO service_role;

CREATE OR REPLACE FUNCTION public.queue_fan_team_invitation_push_notification(
  p_invitation_id uuid,
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
  IF p_invitation_id IS NULL OR p_event_id IS NULL THEN
    RETURN;
  END IF;

  IF to_regnamespace('net') IS NULL OR to_regclass('vault.decrypted_secrets') IS NULL THEN
    RAISE NOTICE 'fan team invitation push skipped: pg_net or vault unavailable';
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
    RAISE NOTICE 'fan team invitation push skipped: vault secrets missing';
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

  PERFORM net.http_post(
    url := v_url || '/functions/v1/notify-fan-team-invitation',
    headers := v_headers,
    body := jsonb_build_object(
      'invitation_id', p_invitation_id,
      'event_id', p_event_id
    ),
    timeout_milliseconds := 15000
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'fan team invitation push queue failed: %', SQLERRM;
END;
$$;

REVOKE ALL ON FUNCTION public.queue_fan_team_invitation_push_notification(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.queue_fan_team_invitation_push_notification(uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.queue_fan_team_invitation_push_notification(uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.queue_fan_team_invitation_push_notification(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3) Rate-limit allowlist (preserve prior buckets + invitation buckets)
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
  -- Preserve production allowlist from 20260927; only append Team invitation buckets.
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
    'decline_fan_team_invitation'
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

  -- Production cleanup: ~1% of calls prune windows older than 7 days.
  IF (random() < 0.01) THEN
    DELETE FROM public.rpc_rate_limits
    WHERE window_start < (now() - interval '7 days');
  END IF;
END;
$$;

COMMENT ON FUNCTION public.assert_rpc_rate_limit(text, int, int) IS
  'SECURITY DEFINER fixed-window rate limit with allowlisted buckets (includes search_chat_*, create_fan_team, and Fan Team invitation buckets). Raises generic 54000 rate_limit_exceeded. Not granted to authenticated clients.';

-- Match production grants from 20260918/20260927: internal helper only.
REVOKE ALL ON FUNCTION public.assert_rpc_rate_limit(text, int, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.assert_rpc_rate_limit(text, int, int) FROM anon;
REVOKE ALL ON FUNCTION public.assert_rpc_rate_limit(text, int, int) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.assert_rpc_rate_limit(text, int, int) TO service_role;

-- ---------------------------------------------------------------------------
-- 4) Internal pending invite insert (+ optional push)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fan_team_insert_pending_invitation(
  p_team_id uuid,
  p_inviter_user_id uuid,
  p_invitee_user_id uuid,
  p_queue_push boolean DEFAULT true
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id uuid;
  v_existing uuid;
  v_event_id uuid;
  v_is_new boolean := false;
BEGIN
  IF NOT public.group_add_member_eligible(p_inviter_user_id, p_invitee_user_id) THEN
    RAISE EXCEPTION 'One or more invitees are not eligible.' USING ERRCODE = '42501';
  END IF;

  IF public.is_active_fan_team_member(p_team_id, p_invitee_user_id) THEN
    RETURN NULL;
  END IF;

  UPDATE public.fan_team_invitations
  SET status = 'expired', responded_at = coalesce(responded_at, now())
  WHERE team_id = p_team_id
    AND invitee_user_id = p_invitee_user_id
    AND status = 'pending'
    AND expires_at IS NOT NULL
    AND expires_at <= now();

  SELECT i.id
    INTO v_existing
  FROM public.fan_team_invitations i
  WHERE i.team_id = p_team_id
    AND i.invitee_user_id = p_invitee_user_id
    AND i.status = 'pending'
    AND (i.expires_at IS NULL OR i.expires_at > now())
  LIMIT 1;

  IF v_existing IS NOT NULL THEN
    RETURN v_existing; -- idempotent; no second push
  END IF;

  INSERT INTO public.fan_team_invitations (
    team_id, inviter_user_id, invitee_user_id, status, expires_at
  ) VALUES (
    p_team_id,
    p_inviter_user_id,
    p_invitee_user_id,
    'pending',
    now() + interval '30 days'
  )
  RETURNING id INTO v_id;
  v_is_new := true;

  IF v_is_new AND p_queue_push THEN
    v_event_id := gen_random_uuid();
    PERFORM public.queue_fan_team_invitation_push_notification(v_id, v_event_id);
  END IF;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.fan_team_insert_pending_invitation(uuid, uuid, uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fan_team_insert_pending_invitation(uuid, uuid, uuid, boolean) TO service_role;

-- ---------------------------------------------------------------------------
-- 5) create_fan_team — owner only active; p_member_ids = invitees
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_fan_team(
  p_name text,
  p_sport text DEFAULT '',
  p_member_ids uuid[] DEFAULT ARRAY[]::uuid[],
  p_color_hex text DEFAULT NULL,
  p_logo_url text DEFAULT NULL,
  p_logo_thumbnail_url text DEFAULT NULL
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

  -- Capacity: active (1 owner) + pending invites ≤ 50.
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

  -- Creator is the only immediate Team Chat member (admin).
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

  -- Logo URLs are intentionally ignored at create time.
  -- team_id does not exist yet, so fan-team-logos/{team_id}/... cannot be validated.
  -- Clients must: create Team → upload under that team_id → update_fan_team_identity.
  -- Keeping p_logo_* in the signature for compatibility; values are discarded.
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
    owner_user_id,
    group_conversation_id
  ) VALUES (
    v_name,
    v_sport,
    NULL,
    NULL,
    v_color,
    me,
    v_conversation_id
  )
  RETURNING id INTO v_team_id;

  INSERT INTO public.fan_team_members (team_id, user_id, role)
  VALUES (v_team_id, me, 'owner');

  -- Pending invitations only (no fan_team_members / group membership for invitees).
  FOREACH v_uid IN ARRAY v_unique LOOP
    PERFORM public.fan_team_insert_pending_invitation(v_team_id, me, v_uid, true);
  END LOOP;

  RETURN v_team_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_fan_team(text, text, uuid[], text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_fan_team(text, text, uuid[], text, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.create_fan_team(text, text, uuid[], text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_fan_team(text, text, uuid[], text, text, text) TO service_role;

COMMENT ON FUNCTION public.create_fan_team(text, text, uuid[], text, text, text) IS
  'Create Fan Team + linked chat. Creator is sole active owner/admin. p_member_ids receive PENDING invitations (not membership). p_logo_url / p_logo_thumbnail_url are ignored; set logos via update_fan_team_identity after uploading to fan-team-logos/{team_id}/...';

-- ---------------------------------------------------------------------------
-- 6) add_fan_team_members — now creates invitations (signature preserved)
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
      CONTINUE; -- skip ineligible (batch-friendly, matches prior add semantics)
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
    v_id := public.fan_team_insert_pending_invitation(p_team_id, me, v_uid, true);
    IF v_id IS NOT NULL THEN
      v_invited := v_invited + 1;
    END IF;
  END LOOP;

  RETURN v_invited;
END;
$$;

REVOKE ALL ON FUNCTION public.add_fan_team_members(uuid, uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.add_fan_team_members(uuid, uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.add_fan_team_members(uuid, uuid[]) TO service_role;

COMMENT ON FUNCTION public.add_fan_team_members(uuid, uuid[]) IS
  'Owner/Manager: create PENDING Team invitations for eligible users. Returns newly invited count.';

-- ---------------------------------------------------------------------------
-- 7) Accept / decline / cancel
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.accept_fan_team_invitation(p_invitation_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_inv public.fan_team_invitations%ROWTYPE;
  v_conversation_id uuid;
  v_team_active boolean;
  v_payload jsonb;
  v_display text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  PERFORM public.assert_rpc_rate_limit('accept_fan_team_invitation', 60, 3600);

  SELECT * INTO v_inv
  FROM public.fan_team_invitations
  WHERE id = p_invitation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invitation not found.' USING ERRCODE = 'P0002';
  END IF;

  IF v_inv.invitee_user_id <> me THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  IF v_inv.status = 'accepted' THEN
    RETURN v_inv.team_id; -- idempotent
  END IF;

  IF v_inv.status <> 'pending' THEN
    RAISE EXCEPTION 'Invitation is no longer pending.';
  END IF;

  IF v_inv.expires_at IS NOT NULL AND v_inv.expires_at <= now() THEN
    UPDATE public.fan_team_invitations
    SET status = 'expired', responded_at = now()
    WHERE id = v_inv.id;
    RAISE EXCEPTION 'Invitation has expired.';
  END IF;

  SELECT t.group_conversation_id, t.is_active
  INTO v_conversation_id, v_team_active
  FROM public.fan_teams t
  WHERE t.id = v_inv.team_id;

  IF v_conversation_id IS NULL OR v_team_active IS DISTINCT FROM true THEN
    UPDATE public.fan_team_invitations
    SET status = 'cancelled', cancelled_at = now(), responded_at = now()
    WHERE id = v_inv.id AND status = 'pending';
    RAISE EXCEPTION 'Team is no longer available.';
  END IF;

  IF NOT public.group_add_member_eligible(v_inv.inviter_user_id, me) THEN
    UPDATE public.fan_team_invitations
    SET status = 'cancelled', cancelled_at = now(), responded_at = now()
    WHERE id = v_inv.id AND status = 'pending';
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  IF NOT public.is_active_fan_team_member(v_inv.team_id, v_inv.inviter_user_id) THEN
    UPDATE public.fan_team_invitations
    SET status = 'cancelled', cancelled_at = now(), responded_at = now()
    WHERE id = v_inv.id AND status = 'pending';
    RAISE EXCEPTION 'Invitation is no longer valid.';
  END IF;

  IF (
    SELECT count(*)::integer
    FROM public.fan_team_members
    WHERE team_id = v_inv.team_id AND left_at IS NULL
  ) >= 50 THEN
    RAISE EXCEPTION 'A team may have at most 50 members.';
  END IF;

  -- Soft-rejoin Team membership as member.
  INSERT INTO public.fan_team_members (team_id, user_id, role)
  VALUES (v_inv.team_id, me, 'member')
  ON CONFLICT (team_id, user_id) DO UPDATE
    SET left_at = NULL,
        role = CASE
          WHEN public.fan_team_members.role = 'owner' THEN 'owner'
          ELSE 'member'
        END,
        joined_at = CASE
          WHEN public.fan_team_members.left_at IS NOT NULL THEN now()
          ELSE public.fan_team_members.joined_at
        END;

  INSERT INTO public.group_conversation_members (
    conversation_id, user_id, role, joined_at, last_read_at
  ) VALUES (
    v_conversation_id, me, 'member', now(), now()
  )
  ON CONFLICT (conversation_id, user_id) DO UPDATE
    SET left_at = NULL,
        role = CASE
          WHEN public.group_conversation_members.role = 'admin' THEN 'admin'
          ELSE 'member'
        END,
        joined_at = CASE
          WHEN public.group_conversation_members.left_at IS NOT NULL THEN now()
          ELSE public.group_conversation_members.joined_at
        END,
        last_read_at = now();

  UPDATE public.fan_team_invitations
  SET status = 'accepted', responded_at = now()
  WHERE id = v_inv.id AND status = 'pending';

  SELECT COALESCE(NULLIF(btrim(up.display_name), ''), 'Fan')
    INTO v_display
  FROM public.user_profiles up
  WHERE up.id = me;

  v_payload := jsonb_build_object(
    'event', 'member_joined',
    'affected_user_id', me,
    'affected_display_name', v_display,
    'actor_user_id', v_inv.inviter_user_id,
    'fan_team', true
  );

  INSERT INTO public.group_messages (
    conversation_id, sender_id, body, message_type, system_event, system_payload
  ) VALUES (
    v_conversation_id,
    me,
    coalesce(v_display, 'Fan') || ' joined',
    'system',
    'member_joined',
    v_payload
  );

  UPDATE public.group_conversations
  SET
    last_message_at = now(),
    last_message_preview = coalesce(v_display, 'Fan') || ' joined',
    last_message_sender_id = me,
    last_message_type = 'system',
    last_system_event = 'member_joined',
    last_system_payload = v_payload,
    updated_at = now()
  WHERE id = v_conversation_id;

  RETURN v_inv.team_id;
END;
$$;

REVOKE ALL ON FUNCTION public.accept_fan_team_invitation(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.accept_fan_team_invitation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.accept_fan_team_invitation(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.decline_fan_team_invitation(p_invitation_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_inv public.fan_team_invitations%ROWTYPE;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  PERFORM public.assert_rpc_rate_limit('decline_fan_team_invitation', 60, 3600);

  SELECT * INTO v_inv
  FROM public.fan_team_invitations
  WHERE id = p_invitation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invitation not found.' USING ERRCODE = 'P0002';
  END IF;

  IF v_inv.invitee_user_id <> me THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  IF v_inv.status IN ('declined', 'cancelled', 'expired') THEN
    RETURN;
  END IF;

  IF v_inv.status <> 'pending' THEN
    RAISE EXCEPTION 'Invitation is no longer pending.';
  END IF;

  UPDATE public.fan_team_invitations
  SET status = 'declined', responded_at = now()
  WHERE id = v_inv.id AND status = 'pending';
END;
$$;

REVOKE ALL ON FUNCTION public.decline_fan_team_invitation(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.decline_fan_team_invitation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.decline_fan_team_invitation(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.cancel_fan_team_invitation(p_invitation_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_inv public.fan_team_invitations%ROWTYPE;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  SELECT * INTO v_inv
  FROM public.fan_team_invitations
  WHERE id = p_invitation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invitation not found.' USING ERRCODE = 'P0002';
  END IF;

  IF NOT public.fan_team_viewer_can_manage(v_inv.team_id) THEN
    RAISE EXCEPTION 'Only the owner or a manager can cancel invitations.';
  END IF;

  IF v_inv.status IN ('cancelled', 'declined', 'expired', 'accepted') THEN
    RETURN;
  END IF;

  IF v_inv.status <> 'pending' THEN
    RAISE EXCEPTION 'Invitation is no longer pending.';
  END IF;

  UPDATE public.fan_team_invitations
  SET status = 'cancelled', cancelled_at = now(), responded_at = now()
  WHERE id = v_inv.id AND status = 'pending';
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_fan_team_invitation(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancel_fan_team_invitation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_fan_team_invitation(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 8) List RPCs
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_my_pending_fan_team_invitations()
RETURNS TABLE (
  invitation_id uuid,
  team_id uuid,
  team_name text,
  sport text,
  logo_url text,
  logo_thumbnail_url text,
  color_hex text,
  member_count integer,
  inviter_user_id uuid,
  inviter_display_name text,
  inviter_username text,
  created_at timestamptz,
  expires_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  -- Expire stale rows opportunistically for this invitee.
  UPDATE public.fan_team_invitations i
  SET status = 'expired', responded_at = coalesce(i.responded_at, now())
  WHERE i.invitee_user_id = me
    AND i.status = 'pending'
    AND i.expires_at IS NOT NULL
    AND i.expires_at <= now();

  RETURN QUERY
  SELECT
    i.id AS invitation_id,
    t.id AS team_id,
    t.name AS team_name,
    t.sport,
    t.logo_url,
    t.logo_thumbnail_url,
    t.color_hex,
    (
      SELECT count(*)::integer
      FROM public.fan_team_members m
      WHERE m.team_id = t.id AND m.left_at IS NULL
    ) AS member_count,
    i.inviter_user_id,
    COALESCE(NULLIF(btrim(up.display_name), ''), 'Fan') AS inviter_display_name,
    up.username AS inviter_username,
    i.created_at,
    i.expires_at
  FROM public.fan_team_invitations i
  JOIN public.fan_teams t ON t.id = i.team_id AND t.is_active = true
  LEFT JOIN public.user_profiles up ON up.id = i.inviter_user_id
  WHERE i.invitee_user_id = me
    AND i.status = 'pending'
    AND (i.expires_at IS NULL OR i.expires_at > now())
  ORDER BY i.created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.list_my_pending_fan_team_invitations() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_my_pending_fan_team_invitations() TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_my_pending_fan_team_invitations() TO service_role;

CREATE OR REPLACE FUNCTION public.list_fan_team_pending_invitations(p_team_id uuid)
RETURNS TABLE (
  invitation_id uuid,
  invitee_user_id uuid,
  invitee_display_name text,
  invitee_username text,
  invitee_avatar_url text,
  invitee_avatar_thumbnail_url text,
  inviter_user_id uuid,
  created_at timestamptz,
  expires_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  IF NOT public.fan_team_viewer_can_manage(p_team_id) THEN
    RAISE EXCEPTION 'Only the owner or a manager can view pending invitations.';
  END IF;

  UPDATE public.fan_team_invitations i
  SET status = 'expired', responded_at = coalesce(i.responded_at, now())
  WHERE i.team_id = p_team_id
    AND i.status = 'pending'
    AND i.expires_at IS NOT NULL
    AND i.expires_at <= now();

  RETURN QUERY
  SELECT
    i.id AS invitation_id,
    i.invitee_user_id,
    COALESCE(NULLIF(btrim(up.display_name), ''), 'Fan') AS invitee_display_name,
    up.username AS invitee_username,
    up.avatar_url AS invitee_avatar_url,
    up.avatar_thumbnail_url AS invitee_avatar_thumbnail_url,
    i.inviter_user_id,
    i.created_at,
    i.expires_at
  FROM public.fan_team_invitations i
  LEFT JOIN public.user_profiles up ON up.id = i.invitee_user_id
  WHERE i.team_id = p_team_id
    AND i.status = 'pending'
    AND (i.expires_at IS NULL OR i.expires_at > now())
  ORDER BY i.created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.list_fan_team_pending_invitations(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_fan_team_pending_invitations(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_fan_team_pending_invitations(uuid) TO service_role;

COMMIT;

-- =============================================================================
-- MANUAL APPLY NOTES (do not apply from the agent)
-- =============================================================================
-- Preferred order:
--   1) 20260926_0001_fan_teams.sql                         (if needed)
--   2) 20260927_0001_create_fan_team_rate_limit_bucket.sql (if needed)
--   3) 20260928_0001_update_fan_team_identity.sql          (if needed)
--   4) 20260929_0001_fan_team_invitations.sql              (THIS FILE)
--
-- Verify assert_rpc_rate_limit production semantics preserved:
--   SELECT pg_get_functiondef(
--     'public.assert_rpc_rate_limit(text,integer,integer)'::regprocedure
--   ) ILIKE ALL (ARRAY[
--     '%random() < 0.01%',
--     '%interval ''7 days''%',
--     '%send_direct_message%',
--     '%send_group_message%',
--     '%friendship_ensure_pending%',
--     '%poke_profile%',
--     '%report_group_message%',
--     '%search_chat_conversations%',
--     '%search_chat_messages%',
--     '%create_fan_team%',
--     '%invite_fan_team_members%',
--     '%accept_fan_team_invitation%',
--     '%decline_fan_team_invitation%'
--   ]);
--
-- Confirm authenticated cannot EXECUTE assert_rpc_rate_limit:
--   SELECT has_function_privilege(
--     'authenticated',
--     'public.assert_rpc_rate_limit(text,integer,integer)',
--     'EXECUTE'
--   );  -- expect false
--
-- Confirm create_fan_team does not persist create-time logo args:
--   SELECT pg_get_functiondef(
--     'public.create_fan_team(text,text,uuid[],text,text,text)'::regprocedure
--   ) ILIKE '%ignored logo URL%'
--   AND pg_get_functiondef(
--     'public.create_fan_team(text,text,uuid[],text,text,text)'::regprocedure
--   ) NOT ILIKE '%nullif(btrim(coalesce(p_logo_url%';
--
-- Edge (separate, optional for push):
--   supabase functions deploy notify-fan-team-invitation --no-verify-jwt
-- =============================================================================
