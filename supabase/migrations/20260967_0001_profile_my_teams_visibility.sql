-- =============================================================================
-- 20260967_0001 — Profile "My Teams" visibility + privacy-gated public summary
-- =============================================================================
-- Phase 1: ONE global profile visibility setting for FanGeo Fan Team memberships
-- shown on user profiles. Distinct from Favorite Teams (catalog clubs).
--
-- Does NOT loosen fan_teams / fan_team_members table RLS.
-- Public disclosure only via SECURITY DEFINER RPC returning minimal safe fields.
--
-- Default: only_me (privacy-safe; invitation-only Teams; opt-in social disclosure).
-- Owner always sees their own memberships client-side via list_my_fan_teams.
--
-- Do NOT apply from the agent; review and apply deliberately in Supabase.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Global visibility column on user_profiles
-- ---------------------------------------------------------------------------

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS my_teams_profile_visibility text NOT NULL DEFAULT 'only_me';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'user_profiles_my_teams_profile_visibility_ck'
  ) THEN
    ALTER TABLE public.user_profiles
      ADD CONSTRAINT user_profiles_my_teams_profile_visibility_ck
      CHECK (
        my_teams_profile_visibility IN (
          'everyone',
          'friends',
          'team_members',
          'only_me'
        )
      );
  END IF;
END $$;

COMMENT ON COLUMN public.user_profiles.my_teams_profile_visibility IS
  'Who may see the profile owner''s active FanGeo Team memberships (not Favorite Teams). '
  'everyone | friends | team_members | only_me. Default only_me. Future per-Team toggles can layer on top.';

-- ---------------------------------------------------------------------------
-- 2) Shared-active-Fan-Team helper (account seats only; not managed-player seats)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.users_share_active_fan_team(
  p_user_a uuid,
  p_user_b uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.fan_team_members a
    INNER JOIN public.fan_team_members b
      ON b.team_id = a.team_id
     AND b.left_at IS NULL
     AND b.user_id IS NOT NULL
     AND b.managed_player_id IS NULL
     AND b.user_id = p_user_b
    INNER JOIN public.fan_teams t
      ON t.id = a.team_id
     AND t.is_active = true
    WHERE a.left_at IS NULL
      AND a.user_id IS NOT NULL
      AND a.managed_player_id IS NULL
      AND a.user_id = p_user_a
      AND p_user_a IS DISTINCT FROM p_user_b
  );
$$;

COMMENT ON FUNCTION public.users_share_active_fan_team(uuid, uuid) IS
  'True when both users have active account seats on the same active Fan Team. Ignores managed-player seats.';

REVOKE ALL ON FUNCTION public.users_share_active_fan_team(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.users_share_active_fan_team(uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.users_share_active_fan_team(uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.users_share_active_fan_team(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3) Public / privacy-gated memberships list
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.list_profile_fan_team_memberships(
  p_target_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_viewer uuid := auth.uid();
  v_target uuid := p_target_user_id;
  v_visibility text := 'only_me';
  v_allowed boolean := false;
  v_is_self boolean := false;
  v_is_friend boolean := false;
  v_share_team boolean := false;
  v_rows jsonb := '[]'::jsonb;
BEGIN
  IF v_viewer IS NULL OR v_target IS NULL THEN
    RETURN jsonb_build_object(
      'visible', false,
      'visibility', 'only_me',
      'memberships', '[]'::jsonb
    );
  END IF;

  v_is_self := (v_viewer = v_target);

  -- Profile access gate (same spirit as get_public_fan_identity_profile), except self.
  IF NOT v_is_self THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.user_profiles up
      WHERE up.id::text = v_target::text
        AND COALESCE(lower(trim(up.admin_status)), '') = 'active'
        AND up.admin_disabled_at IS NULL
        AND COALESCE(up.is_business_account, false) = false
        AND (
          COALESCE(up.discoverable_by_fans, true) = true
          OR public.pickup_invite_users_are_friends(v_viewer, v_target)
        )
        AND COALESCE(up.is_deleted, false) = false
        AND NOT lower(trim(coalesce(up.email, ''))) LIKE '%@deleted.fangeo.local'
    ) THEN
      RETURN jsonb_build_object(
        'visible', false,
        'visibility', 'only_me',
        'memberships', '[]'::jsonb
      );
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.blocked_users b
      WHERE (b.blocker_user_id::text = v_viewer::text AND b.blocked_user_id::text = v_target::text)
         OR (b.blocker_user_id::text = v_target::text AND b.blocked_user_id::text = v_viewer::text)
    ) THEN
      RETURN jsonb_build_object(
        'visible', false,
        'visibility', 'only_me',
        'memberships', '[]'::jsonb
      );
    END IF;
  END IF;

  SELECT COALESCE(up.my_teams_profile_visibility, 'only_me')
  INTO v_visibility
  FROM public.user_profiles up
  WHERE up.id::text = v_target::text
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'visible', false,
      'visibility', 'only_me',
      'memberships', '[]'::jsonb
    );
  END IF;

  v_is_friend := public.pickup_invite_users_are_friends(v_viewer, v_target);
  v_share_team := public.users_share_active_fan_team(v_viewer, v_target);

  IF v_is_self THEN
    v_allowed := true;
  ELSE
    CASE v_visibility
      WHEN 'everyone' THEN
        v_allowed := true;
      WHEN 'friends' THEN
        v_allowed := v_is_friend;
      WHEN 'team_members' THEN
        v_allowed := v_share_team;
      ELSE
        -- only_me and unknown
        v_allowed := false;
    END CASE;
  END IF;

  IF NOT v_allowed THEN
    RETURN jsonb_build_object(
      'visible', false,
      'visibility', v_visibility,
      'memberships', '[]'::jsonb
    );
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'team_id', t.id,
        'name', t.name,
        'sport', COALESCE(t.sport, ''),
        'logo_url', t.logo_url,
        'logo_thumbnail_url', t.logo_thumbnail_url,
        'color_hex', t.color_hex,
        'role', m.role,
        'viewer_can_open', (
          v_is_self
          OR public.is_active_fan_team_member(t.id, v_viewer)
        )
      )
      ORDER BY lower(t.name), t.id
    ),
    '[]'::jsonb
  )
  INTO v_rows
  FROM public.fan_team_members m
  INNER JOIN public.fan_teams t
    ON t.id = m.team_id
   AND t.is_active = true
  WHERE m.user_id = v_target
    AND m.left_at IS NULL
    AND m.managed_player_id IS NULL;

  RETURN jsonb_build_object(
    'visible', true,
    'visibility', v_visibility,
    'memberships', COALESCE(v_rows, '[]'::jsonb)
  );
END;
$$;

COMMENT ON FUNCTION public.list_profile_fan_team_memberships(uuid) IS
  'Privacy-gated FanGeo Team memberships for a profile. Active account seats only. '
  'Minimal safe fields (no roster/schedule/chat). Enforces my_teams_profile_visibility.';

REVOKE ALL ON FUNCTION public.list_profile_fan_team_memberships(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_profile_fan_team_memberships(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.list_profile_fan_team_memberships(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_profile_fan_team_memberships(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 4) Setter RPC (validated tokens; rate-limited)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.set_my_teams_profile_visibility(
  p_visibility text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_vis text := lower(btrim(coalesce(p_visibility, '')));
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;

  IF v_vis NOT IN ('everyone', 'friends', 'team_members', 'only_me') THEN
    RAISE EXCEPTION 'invalid my_teams_profile_visibility' USING ERRCODE = '22023';
  END IF;

  PERFORM public.assert_rpc_rate_limit('set_my_teams_profile_visibility', 30, 3600);

  UPDATE public.user_profiles up
  SET my_teams_profile_visibility = v_vis
  WHERE up.id = me;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'profile not found' USING ERRCODE = 'P0002';
  END IF;

  RETURN v_vis;
END;
$$;

COMMENT ON FUNCTION public.set_my_teams_profile_visibility(text) IS
  'Caller updates global My Teams profile visibility. Tokens: everyone|friends|team_members|only_me.';

REVOKE ALL ON FUNCTION public.set_my_teams_profile_visibility(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_my_teams_profile_visibility(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_my_teams_profile_visibility(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_my_teams_profile_visibility(text) TO service_role;

-- ---------------------------------------------------------------------------
-- 5) Rate-limit allowlist (+ set_my_teams_profile_visibility)
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
    'create_managed_player',
    'update_managed_player',
    'add_managed_player_to_fan_team',
    'accept_fan_team_invitation_as_managed_player',
    'accept_fan_team_invitation_for_participants',
    'set_my_teams_profile_visibility'
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

COMMIT;
