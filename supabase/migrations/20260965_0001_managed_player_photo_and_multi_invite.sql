-- =============================================================================
-- 20260965_0001 — Managed player photo clear + multi-participant invitation accept
-- =============================================================================
-- Preserves 20260960/61 architecture (no second player system, no child accounts).
--
-- 1) update_managed_player — additive p_clear_avatar (clear URL fields)
-- 2) accept_fan_team_invitation_for_participants — atomic self + N managed seats
-- 3) accept_fan_team_invitation_as_managed_player — delegates to (2)
-- 4) Rate-limit allowlist — accept_fan_team_invitation_for_participants
--
-- Chat: managed seats NEVER insert into group_conversation_members.
-- Invitation is consumed once after all requested seats succeed.
-- Do NOT apply from the agent.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) update_managed_player — clear avatar support
-- ---------------------------------------------------------------------------
-- New optional arg changes the Postgres signature; drop the 20260960 overload
-- so PostgREST resolves a single function with defaults.
DROP FUNCTION IF EXISTS public.update_managed_player(
  uuid, text, text, text, int, text, text, boolean
);

CREATE OR REPLACE FUNCTION public.update_managed_player(
  p_managed_player_id uuid,
  p_first_name text DEFAULT NULL,
  p_last_name text DEFAULT NULL,
  p_display_name text DEFAULT NULL,
  p_birth_year int DEFAULT NULL,
  p_avatar_url text DEFAULT NULL,
  p_avatar_thumbnail_url text DEFAULT NULL,
  p_clear_birth_year boolean DEFAULT false,
  p_clear_avatar boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_first text := nullif(btrim(coalesce(p_first_name, '')), '');
  v_last text := p_last_name;
  v_display text := nullif(btrim(coalesce(p_display_name, '')), '');
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF NOT public.is_authorized_managed_player_guardian(p_managed_player_id, me) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  PERFORM public.assert_rpc_rate_limit('update_managed_player', 60, 3600);

  IF v_first IS NOT NULL AND char_length(v_first) > 40 THEN
    RAISE EXCEPTION 'managed_player_first_name_invalid' USING ERRCODE = 'check_violation';
  END IF;
  IF v_last IS NOT NULL AND char_length(btrim(v_last)) > 40 THEN
    RAISE EXCEPTION 'managed_player_last_name_invalid' USING ERRCODE = 'check_violation';
  END IF;
  IF v_display IS NOT NULL AND char_length(v_display) > 60 THEN
    RAISE EXCEPTION 'managed_player_display_name_invalid' USING ERRCODE = 'check_violation';
  END IF;
  IF p_birth_year IS NOT NULL
     AND (p_birth_year < 1900 OR p_birth_year > extract(year FROM now())::int) THEN
    RAISE EXCEPTION 'managed_player_birth_year_invalid' USING ERRCODE = 'check_violation';
  END IF;

  UPDATE public.fan_managed_players
  SET
    first_name = coalesce(v_first, first_name),
    last_name = coalesce(btrim(v_last), last_name),
    display_name = coalesce(v_display, display_name),
    birth_year = CASE
      WHEN p_clear_birth_year THEN NULL
      ELSE coalesce(p_birth_year, birth_year)
    END,
    avatar_url = CASE
      WHEN p_clear_avatar THEN NULL
      ELSE coalesce(nullif(btrim(coalesce(p_avatar_url, '')), ''), avatar_url)
    END,
    avatar_thumbnail_url = CASE
      WHEN p_clear_avatar THEN NULL
      ELSE coalesce(
        nullif(btrim(coalesce(p_avatar_thumbnail_url, '')), ''),
        avatar_thumbnail_url
      )
    END,
    updated_at = now()
  WHERE id = p_managed_player_id
    AND archived_at IS NULL;
END;
$$;

COMMENT ON FUNCTION public.update_managed_player(
  uuid, text, text, text, int, text, text, boolean, boolean
) IS
  'Guardian update for a managed player. p_clear_avatar clears both avatar URL fields.';

REVOKE ALL ON FUNCTION public.update_managed_player(
  uuid, text, text, text, int, text, text, boolean, boolean
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_managed_player(
  uuid, text, text, text, int, text, text, boolean, boolean
) FROM anon;
GRANT EXECUTE ON FUNCTION public.update_managed_player(
  uuid, text, text, text, int, text, text, boolean, boolean
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_managed_player(
  uuid, text, text, text, int, text, text, boolean, boolean
) TO service_role;

-- ---------------------------------------------------------------------------
-- 2) Multi-participant invitation accept (atomic)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.accept_fan_team_invitation_for_participants(
  p_invitation_id uuid,
  p_include_self boolean DEFAULT false,
  p_managed_player_ids uuid[] DEFAULT ARRAY[]::uuid[]
)
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
  v_ids uuid[];
  v_id uuid;
  v_active_count int;
  v_new_seats int := 0;
  v_self_active boolean := false;
  v_membership_id uuid;
  v_names text[] := ARRAY[]::text[];
  v_display text;
  v_child_name text;
  v_payload jsonb;
  v_body text;
  v_needs_managed_flag boolean := false;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  PERFORM public.assert_rpc_rate_limit('accept_fan_team_invitation_for_participants', 60, 3600);

  -- Deduplicate + drop nulls.
  SELECT coalesce(array_agg(DISTINCT x ORDER BY x), ARRAY[]::uuid[])
  INTO v_ids
  FROM unnest(coalesce(p_managed_player_ids, ARRAY[]::uuid[])) AS x
  WHERE x IS NOT NULL;

  IF NOT coalesce(p_include_self, false) AND coalesce(array_length(v_ids, 1), 0) = 0 THEN
    RAISE EXCEPTION 'managed_player_invite_selection_empty'
      USING ERRCODE = 'check_violation';
  END IF;

  IF coalesce(array_length(v_ids, 1), 0) > 0 THEN
    v_needs_managed_flag := true;
  END IF;

  IF v_needs_managed_flag
     AND NOT public.is_fan_geo_runtime_flag_enabled('managed_player_team_seats') THEN
    RAISE EXCEPTION 'managed_player_seats_disabled'
      USING ERRCODE = 'check_violation';
  END IF;

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
    RETURN v_inv.team_id; -- fully consumed already
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

  IF NOT public.is_active_fan_team_member(v_inv.team_id, v_inv.inviter_user_id) THEN
    UPDATE public.fan_team_invitations
    SET status = 'cancelled', cancelled_at = now(), responded_at = now()
    WHERE id = v_inv.id AND status = 'pending';
    RAISE EXCEPTION 'Invitation is no longer valid.';
  END IF;

  -- Self join still requires the same eligibility as the classic accept path.
  IF coalesce(p_include_self, false)
     AND NOT public.group_add_member_eligible(v_inv.inviter_user_id, me) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  -- Authorize every managed player + count NEW seats.
  FOREACH v_id IN ARRAY v_ids LOOP
    IF NOT public.is_authorized_managed_player_guardian(v_id, me) THEN
      RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
    END IF;
    IF NOT EXISTS (
      SELECT 1
      FROM public.fan_team_members m
      WHERE m.team_id = v_inv.team_id
        AND m.managed_player_id = v_id
        AND m.left_at IS NULL
    ) THEN
      v_new_seats := v_new_seats + 1;
    END IF;
  END LOOP;

  IF coalesce(p_include_self, false) THEN
    v_self_active := public.is_active_fan_team_member(v_inv.team_id, me);
    IF NOT v_self_active THEN
      v_new_seats := v_new_seats + 1;
    END IF;
  END IF;

  SELECT count(*)::int INTO v_active_count
  FROM public.fan_team_members
  WHERE team_id = v_inv.team_id AND left_at IS NULL;

  IF v_active_count + v_new_seats > 50 THEN
    RAISE EXCEPTION 'A team may have at most 50 members.';
  END IF;

  -- Self seat + Team Chat (account only).
  IF coalesce(p_include_self, false) THEN
    IF NOT v_self_active THEN
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

      SELECT COALESCE(NULLIF(btrim(up.display_name), ''), 'Fan')
        INTO v_display
      FROM public.user_profiles up
      WHERE up.id = me;
      v_names := array_append(v_names, coalesce(v_display, 'Fan'));
    ELSE
      -- Already an active member: still ensure Team Chat membership is active.
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
            last_read_at = coalesce(public.group_conversation_members.last_read_at, now());
    END IF;
  END IF;

  -- Managed seats (never chat).
  FOREACH v_id IN ARRAY v_ids LOOP
    SELECT m.membership_id INTO v_membership_id
    FROM public.fan_team_members m
    WHERE m.team_id = v_inv.team_id
      AND m.managed_player_id = v_id
      AND m.left_at IS NULL
    LIMIT 1;

    IF v_membership_id IS NULL THEN
      SELECT m.membership_id INTO v_membership_id
      FROM public.fan_team_members m
      WHERE m.team_id = v_inv.team_id
        AND m.managed_player_id = v_id
        AND m.left_at IS NOT NULL
      ORDER BY m.joined_at DESC
      LIMIT 1;

      IF v_membership_id IS NULL THEN
        INSERT INTO public.fan_team_members (team_id, user_id, managed_player_id, role)
        VALUES (v_inv.team_id, NULL, v_id, 'member');
      ELSE
        UPDATE public.fan_team_members
        SET left_at = NULL,
            joined_at = now(),
            role = 'member'
        WHERE membership_id = v_membership_id;
      END IF;

      SELECT COALESCE(NULLIF(btrim(p.display_name), ''), NULLIF(btrim(p.first_name), ''), 'Player')
        INTO v_child_name
      FROM public.fan_managed_players p
      WHERE p.id = v_id;
      v_names := array_append(v_names, coalesce(v_child_name, 'Player'));
    END IF;
  END LOOP;

  UPDATE public.fan_team_invitations
  SET status = 'accepted', responded_at = now()
  WHERE id = v_inv.id AND status = 'pending';

  -- One coherent Team Chat system notice (account actor only).
  IF coalesce(array_length(v_names, 1), 0) > 0 THEN
    IF array_length(v_names, 1) = 1 THEN
      v_body := v_names[1] || ' joined';
    ELSIF array_length(v_names, 1) = 2 THEN
      v_body := v_names[1] || ' and ' || v_names[2] || ' joined';
    ELSE
      v_body := array_to_string(v_names[1:array_length(v_names, 1) - 1], ', ')
        || ', and ' || v_names[array_length(v_names, 1)] || ' joined';
    END IF;

    v_payload := jsonb_build_object(
      'event', 'member_joined',
      'affected_user_id', CASE WHEN coalesce(p_include_self, false) THEN me ELSE NULL END,
      'affected_display_name', v_body,
      'actor_user_id', me,
      'fan_team', true,
      'managed_player_ids', to_jsonb(v_ids),
      'include_self', coalesce(p_include_self, false)
    );

    INSERT INTO public.group_messages (
      conversation_id, sender_id, body, message_type, system_event, system_payload
    ) VALUES (
      v_conversation_id,
      me,
      v_body,
      'system',
      'member_joined',
      v_payload
    );

    UPDATE public.group_conversations
    SET
      last_message_at = now(),
      last_message_preview = left(v_body, 180),
      last_message_sender_id = me,
      last_message_type = 'system',
      last_system_event = 'member_joined',
      last_system_payload = v_payload,
      updated_at = now()
    WHERE id = v_conversation_id;
  END IF;

  RETURN v_inv.team_id;
END;
$$;

REVOKE ALL ON FUNCTION public.accept_fan_team_invitation_for_participants(uuid, boolean, uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.accept_fan_team_invitation_for_participants(uuid, boolean, uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.accept_fan_team_invitation_for_participants(uuid, boolean, uuid[]) TO service_role;

COMMENT ON FUNCTION public.accept_fan_team_invitation_for_participants(uuid, boolean, uuid[]) IS
  'Atomic Team invitation accept for Myself and/or one-or-more managed players. '
  'Consumes the invitation once. Managed seats never join Team Chat.';

-- ---------------------------------------------------------------------------
-- 3) Legacy single managed accept → delegates to multi RPC
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.accept_fan_team_invitation_as_managed_player(
  p_invitation_id uuid,
  p_managed_player_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_managed_player_id IS NULL THEN
    RAISE EXCEPTION 'managed_player_id required' USING ERRCODE = 'check_violation';
  END IF;
  RETURN public.accept_fan_team_invitation_for_participants(
    p_invitation_id,
    false,
    ARRAY[p_managed_player_id]::uuid[]
  );
END;
$$;

COMMENT ON FUNCTION public.accept_fan_team_invitation_as_managed_player(uuid, uuid) IS
  'Backward-compatible single managed-player invite accept. Delegates to '
  'accept_fan_team_invitation_for_participants.';

-- ---------------------------------------------------------------------------
-- 4) Rate-limit allowlist (preserve 20260963 semantics + multi-accept bucket)
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
    'resend_fan_team_invitation',
    -- 20260960 managed-player buckets
    'create_managed_player',
    'update_managed_player',
    'add_managed_player_to_fan_team',
    'accept_fan_team_invitation_as_managed_player',
    -- 20260965 multi-participant invite accept
    'accept_fan_team_invitation_for_participants'
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
  'SECURITY DEFINER fixed-window rate limit with allowlisted buckets '
  '(includes Fan Team + managed-player + multi-invite buckets).';

REVOKE ALL ON FUNCTION public.assert_rpc_rate_limit(text, int, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.assert_rpc_rate_limit(text, int, int) FROM anon;
REVOKE ALL ON FUNCTION public.assert_rpc_rate_limit(text, int, int) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.assert_rpc_rate_limit(text, int, int) TO service_role;

COMMIT;
