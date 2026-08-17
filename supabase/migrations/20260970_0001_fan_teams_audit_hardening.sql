-- =============================================================================
-- 20260970_0001 — Fan Teams audit remediations (surgical hardening)
-- =============================================================================
-- Fixes (additive / behavior-preserving except proven defects):
--   1) Revoke client EXECUTE on membership/participation probe helpers after
--      introducing viewer-scoped RLS wrappers (DEFINER callers keep working).
--   2) Team Chat admin cannot survive Manager→leave→rejoin-as-Member.
--   3) Managed-player avatar URL namespace validation on create/update writes.
--   4) Additive remove_fan_team_membership(membership_id) for managed seats.
--   5) Additive list_fan_team_schedule_attendance batch read for Schedule.
--   6) Additive managed_player_id on list_my_fan_teams member_avatar_previews.
--
-- Do NOT apply from the agent. Forward-only. No Edge deploy required.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 0) Viewer-scoped helpers for RLS (auth.uid only — no cross-user probe)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_active_fan_team_member_for_viewer(p_team_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.is_active_fan_team_member(p_team_id, auth.uid());
$$;

COMMENT ON FUNCTION public.is_active_fan_team_member_for_viewer(uuid) IS
  'RLS-safe viewer membership check (auth.uid only). Prefer over two-arg probe helper.';

CREATE OR REPLACE FUNCTION public.is_pickup_game_fan_team_participant_for_viewer(
  p_pickup_game_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.is_pickup_game_fan_team_participant(p_pickup_game_id, auth.uid());
$$;

COMMENT ON FUNCTION public.is_pickup_game_fan_team_participant_for_viewer(uuid) IS
  'RLS-safe viewer Team-event participation check (auth.uid only).';

REVOKE ALL ON FUNCTION public.is_active_fan_team_member_for_viewer(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_active_fan_team_member_for_viewer(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.is_active_fan_team_member_for_viewer(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_active_fan_team_member_for_viewer(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.is_pickup_game_fan_team_participant_for_viewer(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_pickup_game_fan_team_participant_for_viewer(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.is_pickup_game_fan_team_participant_for_viewer(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_pickup_game_fan_team_participant_for_viewer(uuid) TO service_role;

-- Pickup SELECT policy: swap two-arg probe for viewer wrapper before revoke.
DROP POLICY IF EXISTS pickup_games_select_authenticated ON public.pickup_games;
CREATE POLICY pickup_games_select_authenticated
  ON public.pickup_games
  FOR SELECT
  TO authenticated
  USING (
    creator_user_id = auth.uid()
    OR (
      status = 'active'
      AND is_visible
      AND (
        remove_after_at IS NULL
        OR remove_after_at > now()
      )
    )
    OR public.can_read_pickup_game_for_requester(id)
    OR public.is_pickup_game_fan_team_participant_for_viewer(id)
  );

-- Lineup / exclusion policies that still reference the two-arg helper (if present).
DO $$
DECLARE
  v_pol text;
BEGIN
  SELECT qual INTO v_pol
  FROM pg_policies
  WHERE schemaname = 'public'
    AND tablename = 'fan_team_event_exclusions'
    AND policyname = 'fan_team_event_exclusions_select'
  LIMIT 1;
  IF v_pol IS NOT NULL AND position('is_active_fan_team_member(team_id, auth.uid())' IN v_pol) > 0 THEN
    DROP POLICY IF EXISTS fan_team_event_exclusions_select ON public.fan_team_event_exclusions;
    CREATE POLICY fan_team_event_exclusions_select ON public.fan_team_event_exclusions
      FOR SELECT TO authenticated
      USING (public.fan_team_viewer_can_access_team(team_id));
  END IF;
END $$;

-- Internal two-arg helpers: no direct client EXECUTE (oracle hardening).
-- SECURITY DEFINER RPCs / viewer wrappers / triggers continue to call them as owner.
REVOKE ALL ON FUNCTION public.is_active_fan_team_member(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_active_fan_team_member(uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.is_active_fan_team_member(uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.is_active_fan_team_member(uuid, uuid) TO service_role;

REVOKE ALL ON FUNCTION public.is_pickup_game_fan_team_participant(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_pickup_game_fan_team_participant(uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.is_pickup_game_fan_team_participant(uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.is_pickup_game_fan_team_participant(uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.is_active_fan_team_member(uuid, uuid) IS
  'INTERNAL helper: active AUTHENTICATED Team membership. Not a client RPC — '
  'EXECUTE revoked from authenticated/anon/PUBLIC (20260970). Use '
  'is_active_fan_team_member_for_viewer for RLS.';

COMMENT ON FUNCTION public.is_pickup_game_fan_team_participant(uuid, uuid) IS
  'INTERNAL helper: Team-linked event participation (account seat or guardian). '
  'Not a client RPC — EXECUTE revoked from authenticated/anon/PUBLIC (20260970). '
  'Use is_pickup_game_fan_team_participant_for_viewer for RLS.';

-- ---------------------------------------------------------------------------
-- 1) Chat role mapping helper (Manager/Owner → chat admin; else member)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fan_team_chat_role_for_team_role(p_team_role text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT CASE
    WHEN lower(btrim(coalesce(p_team_role, ''))) IN ('owner', 'manager') THEN 'admin'
    ELSE 'member'
  END;
$$;

COMMENT ON FUNCTION public.fan_team_chat_role_for_team_role(text) IS
  'Maps Team role → group_conversation_members.role. Owner/Manager = admin; else member.';

REVOKE ALL ON FUNCTION public.fan_team_chat_role_for_team_role(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fan_team_chat_role_for_team_role(text) FROM anon;
REVOKE ALL ON FUNCTION public.fan_team_chat_role_for_team_role(text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.fan_team_chat_role_for_team_role(text) TO service_role;

-- ---------------------------------------------------------------------------
-- 2) leave / remove — clear stale chat admin on soft-leave
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.leave_fan_team(p_team_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_role text;
  v_conversation_id uuid;
  v_owner uuid;
  v_team_name text;
  v_recipients uuid[];
  v_manager_count integer := 0;
  v_left_display text;
  v_event_id uuid := gen_random_uuid();
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  PERFORM public.assert_rpc_rate_limit('leave_fan_team', 30, 3600);

  SELECT t.group_conversation_id, t.owner_user_id, t.name
  INTO v_conversation_id, v_owner, v_team_name
  FROM public.fan_teams t
  WHERE t.id = p_team_id AND t.is_active = true;

  IF v_conversation_id IS NULL THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  SELECT m.role INTO v_role
  FROM public.fan_team_members m
  WHERE m.team_id = p_team_id
    AND m.user_id = me
    AND m.left_at IS NULL;

  IF v_role IS NULL THEN
    RAISE NOTICE
      '[FanTeamMemberLeaveDebug] already_left_or_not_member team_id=% leaving_user_id=%',
      p_team_id, me;
    RETURN;
  END IF;

  IF v_role = 'owner' THEN
    RAISE EXCEPTION 'Team owners cannot leave while they own the Team.';
  END IF;

  SELECT coalesce(array_agg(m.user_id ORDER BY m.user_id), '{}'::uuid[])
  INTO v_recipients
  FROM public.fan_team_members m
  WHERE m.team_id = p_team_id
    AND m.left_at IS NULL
    AND m.user_id <> me
    AND public.fan_team_role_is_manager_or_owner(m.role);

  SELECT count(*)::integer INTO v_manager_count
  FROM unnest(v_recipients) AS r(uid)
  WHERE r.uid IS DISTINCT FROM v_owner;

  SELECT coalesce(
    nullif(btrim(up.display_name), ''),
    nullif(btrim(up.username), ''),
    'A teammate'
  )
  INTO v_left_display
  FROM public.user_profiles up
  WHERE up.id = me;

  v_left_display := coalesce(nullif(btrim(v_left_display), ''), 'A teammate');

  RAISE NOTICE
    '[FanTeamMemberLeaveDebug] leave_begin team_id=% leaving_user_id=% team_name=% owner_user_id=% active_manager_count=% recipient_snapshot=%',
    p_team_id, me, coalesce(v_team_name, ''), v_owner, v_manager_count, cardinality(v_recipients);

  PERFORM public.cleanup_fan_team_member_future_event_participation(p_team_id, me);

  UPDATE public.fan_team_members
  SET left_at = now()
  WHERE team_id = p_team_id
    AND user_id = me
    AND left_at IS NULL;

  -- Soft-leave chat AND demote admin → member so rejoin cannot revive manage rights.
  UPDATE public.group_conversation_members
  SET left_at = now(),
      role = 'member'
  WHERE conversation_id = v_conversation_id
    AND user_id = me
    AND left_at IS NULL;

  UPDATE public.fan_team_invitations
  SET status = 'cancelled', cancelled_at = now(), responded_at = coalesce(responded_at, now())
  WHERE team_id = p_team_id
    AND invitee_user_id = me
    AND status = 'pending';

  UPDATE public.fan_teams
  SET updated_at = now()
  WHERE id = p_team_id;

  IF cardinality(v_recipients) > 0 THEN
    INSERT INTO public.fan_team_member_left_events (
      id, team_id, left_user_id, actor_user_id, reason,
      team_name, left_display_name, recipient_user_ids
    ) VALUES (
      v_event_id,
      p_team_id,
      me,
      me,
      'left',
      coalesce(nullif(btrim(v_team_name), ''), 'Team'),
      v_left_display,
      v_recipients
    );

    PERFORM public.queue_fan_team_member_left_push_notification(v_event_id);
  ELSE
    RAISE NOTICE
      '[FanTeamMemberLeaveDebug] notification_event=no team_id=% reason=no_owner_manager_recipients',
      p_team_id;
  END IF;
END;
$$;

COMMENT ON FUNCTION public.leave_fan_team(uuid) IS
  'Non-owner soft-leave: membership + Team Chat (admin demoted) + invite cancel + '
  'future event cleanup + Owner/Manager member_left_team APNS queue.';

REVOKE ALL ON FUNCTION public.leave_fan_team(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.leave_fan_team(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.leave_fan_team(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.remove_fan_team_member(
  p_team_id uuid,
  p_user_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_target_role text;
  v_conversation_id uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'User is required.';
  END IF;

  SELECT t.group_conversation_id INTO v_conversation_id
  FROM public.fan_teams t
  WHERE t.id = p_team_id AND t.is_active = true;

  IF v_conversation_id IS NULL THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  SELECT m.role INTO v_target_role
  FROM public.fan_team_members m
  WHERE m.team_id = p_team_id
    AND m.user_id = p_user_id
    AND m.left_at IS NULL;

  IF v_target_role IS NULL THEN
    RETURN;
  END IF;

  IF p_user_id = me THEN
    RAISE EXCEPTION 'Use leave_fan_team to leave the Team.';
  END IF;

  IF v_target_role = 'owner' THEN
    RAISE EXCEPTION 'The team owner cannot be removed.';
  END IF;

  IF NOT public.fan_team_viewer_can_manage(p_team_id) THEN
    RAISE EXCEPTION 'Only the owner or a manager can remove members.';
  END IF;

  PERFORM public.cleanup_fan_team_member_future_event_participation(p_team_id, p_user_id);

  UPDATE public.fan_team_members
  SET left_at = now()
  WHERE team_id = p_team_id
    AND user_id = p_user_id
    AND left_at IS NULL;

  UPDATE public.group_conversation_members
  SET left_at = now(),
      role = 'member'
  WHERE conversation_id = v_conversation_id
    AND user_id = p_user_id
    AND left_at IS NULL;

  UPDATE public.fan_teams
  SET updated_at = now()
  WHERE id = p_team_id;

  RAISE NOTICE
    '[FanTeamMemberLeaveDebug] remove_complete team_id=% removed_user_id=% actor=%',
    p_team_id, p_user_id, me;
END;
$$;

COMMENT ON FUNCTION public.remove_fan_team_member(uuid, uuid) IS
  'STAFF soft-remove of another ACCOUNT member + Team Chat leave (admin cleared) + '
  'future Team-event cleanup. Rejects self-removal. Does not remove managed seats '
  '(use remove_fan_team_membership).';

REVOKE ALL ON FUNCTION public.remove_fan_team_member(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.remove_fan_team_member(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_fan_team_member(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3) Invitation accept — never preserve stale chat admin on soft-rejoin
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
        role = public.fan_team_chat_role_for_team_role(
          coalesce(
            (
              SELECT m.role
              FROM public.fan_team_members m
              WHERE m.team_id = v_inv.team_id
                AND m.user_id = me
                AND m.left_at IS NULL
              LIMIT 1
            ),
            'member'
          )
        ),
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

COMMENT ON FUNCTION public.accept_fan_team_invitation(uuid) IS
  'Accept Team invitation as account member. Soft-rejoin sets Team Chat role from '
  'CURRENT Team role (never preserves stale chat admin).';

-- Patch multi-participant accept: preserve 20260965 semantics; only fix stale chat admin.
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
            role = public.fan_team_chat_role_for_team_role(
              coalesce(
                (
                  SELECT m.role
                  FROM public.fan_team_members m
                  WHERE m.team_id = v_inv.team_id
                    AND m.user_id = me
                    AND m.left_at IS NULL
                  LIMIT 1
                ),
                'member'
              )
            ),
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
            role = public.fan_team_chat_role_for_team_role(
              coalesce(
                (
                  SELECT m.role
                  FROM public.fan_team_members m
                  WHERE m.team_id = v_inv.team_id
                    AND m.user_id = me
                    AND m.left_at IS NULL
                  LIMIT 1
                ),
                'member'
              )
            ),
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
  'Atomic invitation accept for self and/or managed seats. Team Chat role follows '
  'CURRENT Team authorization (no stale admin on soft-rejoin). Managed seats never join chat.';

-- Keep set_fan_team_member_role chat sync (already correct); ensure demotion clears admin.
-- (No body change required — already maps non-manager → member.)

-- ---------------------------------------------------------------------------
-- 4) Managed avatar URL validation
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_valid_managed_player_avatar_url(
  p_url text,
  p_guardian_user_id uuid,
  p_managed_player_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_url text := nullif(btrim(coalesce(p_url, '')), '');
  v_path text;
  v_marker text := '/storage/v1/object/public/user-avatars/';
  v_pos int;
  v_prefix text;
BEGIN
  IF v_url IS NULL THEN
    RETURN true;
  END IF;
  IF p_guardian_user_id IS NULL OR p_managed_player_id IS NULL THEN
    RETURN false;
  END IF;

  v_pos := position(v_marker IN v_url);
  IF v_pos > 0 THEN
    v_path := substr(v_url, v_pos + char_length(v_marker));
  ELSIF v_url !~* '^https?://' AND position('://' IN v_url) = 0 THEN
    v_path := v_url;
  ELSE
    RETURN false;
  END IF;

  v_path := split_part(v_path, '?', 1);
  v_path := btrim(v_path);
  IF v_path = '' OR position('..' IN v_path) > 0 THEN
    RETURN false;
  END IF;

  v_prefix := lower(p_guardian_user_id::text) || '/managed-players/' || lower(p_managed_player_id::text) || '/';
  RETURN lower(v_path) LIKE v_prefix || '%';
END;
$$;

COMMENT ON FUNCTION public.is_valid_managed_player_avatar_url(text, uuid, uuid) IS
  'INTERNAL: managed avatar/thumbnail must live under '
  'user-avatars/{guardian}/managed-players/{managed_player_id}/. NULL/empty allowed.';

REVOKE ALL ON FUNCTION public.is_valid_managed_player_avatar_url(text, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_valid_managed_player_avatar_url(text, uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.is_valid_managed_player_avatar_url(text, uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.is_valid_managed_player_avatar_url(text, uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.create_managed_player(
  p_first_name text,
  p_last_name text,
  p_display_name text DEFAULT NULL,
  p_birth_year int DEFAULT NULL,
  p_avatar_url text DEFAULT NULL,
  p_avatar_thumbnail_url text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_first text := btrim(coalesce(p_first_name, ''));
  v_last text := btrim(coalesce(p_last_name, ''));
  v_display text := btrim(coalesce(p_display_name, ''));
  v_id uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;

  PERFORM public.assert_rpc_rate_limit('create_managed_player', 20, 3600);

  IF char_length(v_first) < 1 OR char_length(v_first) > 40 THEN
    RAISE EXCEPTION 'managed_player_first_name_invalid' USING ERRCODE = 'check_violation';
  END IF;
  IF char_length(v_last) > 40 THEN
    RAISE EXCEPTION 'managed_player_last_name_invalid' USING ERRCODE = 'check_violation';
  END IF;

  IF v_display = '' THEN
    v_display := btrim(v_first || ' ' || v_last);
  END IF;
  IF char_length(v_display) > 60 THEN
    v_display := left(v_display, 60);
  END IF;

  IF p_birth_year IS NOT NULL
     AND (p_birth_year < 1900 OR p_birth_year > extract(year FROM now())::int) THEN
    RAISE EXCEPTION 'managed_player_birth_year_invalid' USING ERRCODE = 'check_violation';
  END IF;

  -- Create→upload→update flow: avatar URLs must be NULL on create (id unknown yet).
  IF nullif(btrim(coalesce(p_avatar_url, '')), '') IS NOT NULL
     OR nullif(btrim(coalesce(p_avatar_thumbnail_url, '')), '') IS NOT NULL THEN
    RAISE EXCEPTION 'managed_player_avatar_url_invalid' USING ERRCODE = 'check_violation';
  END IF;

  IF (
    SELECT count(*)
    FROM public.fan_managed_player_guardians g
    JOIN public.fan_managed_players p ON p.id = g.managed_player_id
    WHERE g.guardian_user_id = me
      AND g.revoked_at IS NULL
      AND p.archived_at IS NULL
  ) >= 12 THEN
    RAISE EXCEPTION 'managed_player_limit_reached' USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO public.fan_managed_players (
    created_by_user_id,
    first_name,
    last_name,
    display_name,
    avatar_url,
    avatar_thumbnail_url,
    birth_year
  ) VALUES (
    me,
    v_first,
    v_last,
    v_display,
    NULL,
    NULL,
    p_birth_year
  )
  RETURNING id INTO v_id;

  INSERT INTO public.fan_managed_player_guardians (
    managed_player_id, guardian_user_id, role
  ) VALUES (v_id, me, 'primary_guardian');

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_managed_player(text, text, text, int, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_managed_player(text, text, text, int, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_managed_player(text, text, text, int, text, text) TO service_role;

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
  v_avatar text := nullif(btrim(coalesce(p_avatar_url, '')), '');
  v_thumb text := nullif(btrim(coalesce(p_avatar_thumbnail_url, '')), '');
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

  IF NOT coalesce(p_clear_avatar, false) THEN
    IF NOT public.is_valid_managed_player_avatar_url(v_avatar, me, p_managed_player_id) THEN
      RAISE EXCEPTION 'managed_player_avatar_url_invalid' USING ERRCODE = 'check_violation';
    END IF;
    IF NOT public.is_valid_managed_player_avatar_url(v_thumb, me, p_managed_player_id) THEN
      RAISE EXCEPTION 'managed_player_avatar_url_invalid' USING ERRCODE = 'check_violation';
    END IF;
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
      ELSE coalesce(v_avatar, avatar_url)
    END,
    avatar_thumbnail_url = CASE
      WHEN p_clear_avatar THEN NULL
      ELSE coalesce(v_thumb, avatar_thumbnail_url)
    END,
    updated_at = now()
  WHERE id = p_managed_player_id
    AND archived_at IS NULL;
END;
$$;

COMMENT ON FUNCTION public.update_managed_player(
  uuid, text, text, text, int, text, text, boolean, boolean
) IS
  'Guardian update for a managed player. Avatar URLs must be under the guardian '
  'managed-players namespace (or cleared via p_clear_avatar).';

REVOKE ALL ON FUNCTION public.update_managed_player(
  uuid, text, text, text, int, text, text, boolean, boolean
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_managed_player(
  uuid, text, text, text, int, text, text, boolean, boolean
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_managed_player(
  uuid, text, text, text, int, text, text, boolean, boolean
) TO service_role;

-- ---------------------------------------------------------------------------
-- 5) Additive remove_fan_team_membership (managed + account via membership_id)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cleanup_fan_team_managed_member_future_event_participation(
  p_team_id uuid,
  p_membership_id uuid,
  p_managed_player_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_team_id IS NULL OR p_managed_player_id IS NULL THEN
    RETURN;
  END IF;

  DELETE FROM public.fan_team_event_lineup_members lm
  USING public.fan_team_event_lineups l
  INNER JOIN public.pickup_games g ON g.id = l.pickup_game_id
  WHERE lm.lineup_id = l.id
    AND l.team_id = p_team_id
    AND lm.managed_player_id = p_managed_player_id
    AND g.game_start_at >= now();

  IF p_membership_id IS NOT NULL THEN
    DELETE FROM public.fan_team_event_rsvps r
    USING public.fan_team_game_links l
    INNER JOIN public.pickup_games g ON g.id = l.pickup_game_id
    WHERE r.team_id = p_team_id
      AND r.pickup_game_id = l.pickup_game_id
      AND l.team_id = p_team_id
      AND r.membership_id = p_membership_id
      AND g.game_start_at >= now();
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.cleanup_fan_team_managed_member_future_event_participation(uuid, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cleanup_fan_team_managed_member_future_event_participation(uuid, uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.cleanup_fan_team_managed_member_future_event_participation(uuid, uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.cleanup_fan_team_managed_member_future_event_participation(uuid, uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.remove_fan_team_membership(p_membership_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_team_id uuid;
  v_user_id uuid;
  v_managed_player_id uuid;
  v_role text;
  v_conversation_id uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_membership_id IS NULL THEN
    RAISE EXCEPTION 'Membership is required.';
  END IF;

  SELECT m.team_id, m.user_id, m.managed_player_id, m.role, t.group_conversation_id
  INTO v_team_id, v_user_id, v_managed_player_id, v_role, v_conversation_id
  FROM public.fan_team_members m
  JOIN public.fan_teams t ON t.id = m.team_id AND t.is_active = true
  WHERE m.membership_id = p_membership_id
    AND m.left_at IS NULL;

  IF v_team_id IS NULL THEN
    RETURN;
  END IF;

  IF NOT public.fan_team_viewer_can_manage(v_team_id) THEN
    RAISE EXCEPTION 'Only the owner or a manager can remove members.';
  END IF;

  IF v_role = 'owner' THEN
    RAISE EXCEPTION 'The team owner cannot be removed.';
  END IF;

  -- Account seat: preserve existing remove_fan_team_member semantics.
  IF v_user_id IS NOT NULL THEN
    IF v_user_id = me THEN
      RAISE EXCEPTION 'Use leave_fan_team to leave the Team.';
    END IF;
    PERFORM public.remove_fan_team_member(v_team_id, v_user_id);
    RETURN;
  END IF;

  IF v_managed_player_id IS NULL THEN
    RETURN;
  END IF;

  PERFORM public.cleanup_fan_team_managed_member_future_event_participation(
    v_team_id,
    p_membership_id,
    v_managed_player_id
  );

  UPDATE public.fan_team_members
  SET left_at = now()
  WHERE membership_id = p_membership_id
    AND left_at IS NULL;

  -- Managed seats never hold Team Chat identity — no group_conversation_members update.
  UPDATE public.fan_teams
  SET updated_at = now()
  WHERE id = v_team_id;

  RAISE NOTICE
    '[FanTeamMemberLeaveDebug] remove_membership_complete membership_id=% team_id=% managed_player_id=% actor=%',
    p_membership_id, v_team_id, v_managed_player_id, me;
END;
$$;

COMMENT ON FUNCTION public.remove_fan_team_membership(uuid) IS
  'STAFF soft-remove by membership_id. Account seats delegate to remove_fan_team_member. '
  'Managed seats soft-leave this Team only (no global archive, no chat row).';

REVOKE ALL ON FUNCTION public.remove_fan_team_membership(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.remove_fan_team_membership(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.remove_fan_team_membership(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_fan_team_membership(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 6) Batch Schedule attendance (additive; preserves per-game RPCs)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_fan_team_schedule_attendance(
  p_team_id uuid,
  p_pickup_game_ids uuid[]
)
RETURNS TABLE (
  pickup_game_id uuid,
  roster jsonb,
  self_rsvp text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me uuid := auth.uid();
  v_ids uuid[] := coalesce(p_pickup_game_ids, ARRAY[]::uuid[]);
  v_gid uuid;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.' USING ERRCODE = '42501';
  END IF;
  IF p_team_id IS NULL THEN
    RAISE EXCEPTION 'Team id required.';
  END IF;
  IF NOT public.fan_team_viewer_can_access_team(p_team_id) THEN
    RAISE EXCEPTION 'Not authorized.' USING ERRCODE = '42501';
  END IF;

  FOREACH v_gid IN ARRAY v_ids LOOP
    IF v_gid IS NULL THEN
      CONTINUE;
    END IF;
    IF NOT EXISTS (
      SELECT 1
      FROM public.fan_team_game_links l
      WHERE l.team_id = p_team_id
        AND l.pickup_game_id = v_gid
    ) THEN
      CONTINUE;
    END IF;

    pickup_game_id := v_gid;
    roster := public.get_pickup_game_roster(v_gid);
    self_rsvp := public.get_fan_team_game_rsvp(v_gid);
    RETURN NEXT;
  END LOOP;
END;
$$;

COMMENT ON FUNCTION public.list_fan_team_schedule_attendance(uuid, uuid[]) IS
  'Batched Schedule attendance: roster jsonb + self_rsvp text per Team-linked game. '
  'Preserves get_pickup_game_roster / get_fan_team_game_rsvp semantics.';

REVOKE ALL ON FUNCTION public.list_fan_team_schedule_attendance(uuid, uuid[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_fan_team_schedule_attendance(uuid, uuid[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.list_fan_team_schedule_attendance(uuid, uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_fan_team_schedule_attendance(uuid, uuid[]) TO service_role;

-- ---------------------------------------------------------------------------
-- 7) list_my_fan_teams — additive managed_player_id on avatar previews
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.list_my_fan_teams();

CREATE FUNCTION public.list_my_fan_teams()
RETURNS TABLE (
  team_id uuid,
  name text,
  sport text,
  logo_url text,
  logo_thumbnail_url text,
  color_hex text,
  competition_level text,
  owner_user_id uuid,
  group_conversation_id uuid,
  my_role text,
  member_count integer,
  pending_invitation_count integer,
  push_notifications_muted boolean,
  next_game_starts_at timestamptz,
  next_game_title text,
  next_game_venue text,
  created_at timestamptz,
  member_avatar_previews jsonb
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

  RETURN QUERY
  SELECT
    t.id,
    t.name,
    t.sport,
    t.logo_url,
    t.logo_thumbnail_url,
    t.color_hex,
    t.competition_level,
    t.owner_user_id,
    t.group_conversation_id,
    m.role,
    (
      SELECT count(*)::integer
      FROM public.fan_team_members am
      WHERE am.team_id = t.id
        AND am.left_at IS NULL
    ) AS member_count,
    CASE
      WHEN public.fan_team_role_is_manager_or_owner(m.role) THEN (
        SELECT count(*)::integer
        FROM public.fan_team_invitations i
        WHERE i.team_id = t.id
          AND i.status = 'pending'
          AND (i.expires_at IS NULL OR i.expires_at > now())
      )
      ELSE 0
    END AS pending_invitation_count,
    coalesce(m.push_notifications_muted, false) AS push_notifications_muted,
    ng.game_start_at,
    coalesce(nullif(btrim(ng.title), ''), ng.game_format),
    coalesce(nullif(btrim(ng.address), ''), nullif(btrim(ng.city), '')),
    t.created_at,
    coalesce(previews.member_avatar_previews, '[]'::jsonb) AS member_avatar_previews
  FROM public.fan_teams t
  JOIN public.fan_team_members m
    ON m.team_id = t.id
   AND m.user_id = me
   AND m.left_at IS NULL
  LEFT JOIN LATERAL (
    SELECT
      pg.game_start_at,
      pg.title,
      pg.game_format,
      pg.address,
      pg.city
    FROM public.fan_team_game_links l
    JOIN public.pickup_games pg ON pg.id = l.pickup_game_id
    WHERE l.team_id = t.id
      AND pg.status = 'active'
      AND pg.archived_at IS NULL
      AND pg.game_start_at >= now() - interval '2 hours'
    ORDER BY pg.game_start_at ASC
    LIMIT 1
  ) ng ON true
  LEFT JOIN LATERAL (
    SELECT coalesce(
      jsonb_agg(
        jsonb_strip_nulls(
          jsonb_build_object(
            'membership_id', ranked.membership_id,
            'managed_player_id', ranked.managed_player_id,
            'display_name', ranked.display_name,
            'avatar_url', ranked.avatar_url,
            'avatar_thumbnail_url', ranked.avatar_thumbnail_url,
            'role', ranked.role,
            'is_managed_player', ranked.is_managed_player
          )
        )
        ORDER BY ranked.rank_order
      ),
      '[]'::jsonb
    ) AS member_avatar_previews
    FROM (
      SELECT
        am.membership_id,
        am.managed_player_id,
        am.role,
        CASE
          WHEN am.managed_player_id IS NOT NULL
            THEN coalesce(nullif(btrim(mp.display_name), ''), 'Player')
          ELSE coalesce(nullif(btrim(up.display_name), ''), 'Fan')
        END AS display_name,
        CASE
          WHEN am.managed_player_id IS NOT NULL THEN mp.avatar_url
          ELSE up.avatar_url
        END AS avatar_url,
        CASE
          WHEN am.managed_player_id IS NOT NULL THEN mp.avatar_thumbnail_url
          ELSE up.avatar_thumbnail_url
        END AS avatar_thumbnail_url,
        (am.managed_player_id IS NOT NULL) AS is_managed_player,
        ROW_NUMBER() OVER (
          ORDER BY
            CASE am.role
              WHEN 'owner' THEN 0
              WHEN 'manager' THEN 1
              WHEN 'head_coach' THEN 2
              WHEN 'assistant_coach' THEN 3
              WHEN 'captain' THEN 4
              WHEN 'assistant_captain' THEN 5
              ELSE 6
            END,
            am.joined_at ASC NULLS LAST,
            lower(
              coalesce(
                nullif(btrim(mp.display_name), ''),
                nullif(btrim(up.display_name), ''),
                nullif(btrim(up.username), ''),
                ''
              )
            ) ASC
        ) AS rank_order
      FROM public.fan_team_members am
      LEFT JOIN public.user_profiles up ON up.id = am.user_id
      LEFT JOIN public.fan_managed_players mp ON mp.id = am.managed_player_id
      WHERE am.team_id = t.id
        AND am.left_at IS NULL
    ) ranked
    WHERE ranked.rank_order <= 4
  ) previews ON true
  WHERE t.is_active = true
  ORDER BY t.name ASC;
END;
$$;

COMMENT ON FUNCTION public.list_my_fan_teams() IS
  'Lists active Fan Teams for auth.uid(). member_avatar_previews include additive '
  'managed_player_id for managed seats (older clients ignore unknown keys).';

REVOKE ALL ON FUNCTION public.list_my_fan_teams() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_my_fan_teams() FROM anon;
GRANT EXECUTE ON FUNCTION public.list_my_fan_teams() TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_my_fan_teams() TO service_role;

-- ---------------------------------------------------------------------------
-- 8) Structural asserts
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF has_function_privilege(
    'authenticated',
    'public.is_active_fan_team_member(uuid,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'assert_failed: is_active_fan_team_member still executable by authenticated';
  END IF;
  IF has_function_privilege(
    'authenticated',
    'public.is_pickup_game_fan_team_participant(uuid,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'assert_failed: is_pickup_game_fan_team_participant still executable by authenticated';
  END IF;
  IF NOT has_function_privilege(
    'authenticated',
    'public.is_active_fan_team_member_for_viewer(uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'assert_failed: viewer membership helper missing EXECUTE for authenticated';
  END IF;
  IF NOT has_function_privilege(
    'authenticated',
    'public.remove_fan_team_membership(uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'assert_failed: remove_fan_team_membership missing EXECUTE for authenticated';
  END IF;
  IF NOT has_function_privilege(
    'authenticated',
    'public.list_fan_team_schedule_attendance(uuid,uuid[])',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'assert_failed: list_fan_team_schedule_attendance missing EXECUTE for authenticated';
  END IF;
  IF NOT has_function_privilege(
    'authenticated',
    'public.accept_fan_team_invitation(uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'assert_failed: accept_fan_team_invitation EXECUTE removed';
  END IF;
  IF NOT has_function_privilege(
    'authenticated',
    'public.remove_fan_team_member(uuid,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'assert_failed: remove_fan_team_member EXECUTE removed';
  END IF;
END $$;

COMMIT;
