-- =============================================================================
-- 20260968_0001 — My Teams profile visibility default → everyone (social)
-- =============================================================================
-- FanGeo Teams should be social by default.
--
-- Changes:
--   • Column DEFAULT only_me → everyone (new profiles)
--   • RPC null / missing-profile fallbacks → everyone
--
-- Does NOT mass-update existing only_me rows (preserves intentional Only Me).
-- Client also upgrades never-explicitly-chosen legacy only_me → everyone.
--
-- Do NOT apply from the agent; review and apply deliberately in Supabase.
-- =============================================================================

BEGIN;

ALTER TABLE public.user_profiles
  ALTER COLUMN my_teams_profile_visibility SET DEFAULT 'everyone';

COMMENT ON COLUMN public.user_profiles.my_teams_profile_visibility IS
  'Who may see the profile owner''s active FanGeo Team memberships (not Favorite Teams). '
  'everyone | friends | team_members | only_me. Default everyone (social).';

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
  v_visibility text := 'everyone';
  v_allowed boolean := false;
  v_is_self boolean := false;
  v_is_friend boolean := false;
  v_share_team boolean := false;
  v_rows jsonb := '[]'::jsonb;
BEGIN
  IF v_viewer IS NULL OR v_target IS NULL THEN
    RETURN jsonb_build_object(
      'visible', false,
      'visibility', 'everyone',
      'memberships', '[]'::jsonb
    );
  END IF;

  v_is_self := (v_viewer = v_target);

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
        'visibility', 'everyone',
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
        'visibility', 'everyone',
        'memberships', '[]'::jsonb
      );
    END IF;
  END IF;

  SELECT COALESCE(up.my_teams_profile_visibility, 'everyone')
  INTO v_visibility
  FROM public.user_profiles up
  WHERE up.id::text = v_target::text
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'visible', false,
      'visibility', 'everyone',
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
  'Minimal safe fields (no roster/schedule/chat). Enforces my_teams_profile_visibility. '
  'Unset / missing visibility falls back to everyone.';

COMMIT;
