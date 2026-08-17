-- =============================================================================
-- 20260997_0001 — Team Chat follows Team ACCOUNT ACCESS
-- =============================================================================
-- Proven defect (E = UI + chat membership provisioning):
--   Team Detail hid Chat when access_via = managed_player (guardian / child-only).
--   send_group_message requires is_active_group_member. Managed seats never
--   insert group_conversation_members, so a guardian with Emma-only access
--   could open the Team but had no chat identity.
--
-- Canonical rule:
--   Chat membership tracks fan_team_user_can_access_team (account seat OR
--   guardian of an active managed seat). Independent of is_player.
--
-- set_my_fan_team_is_player does NOT touch group_conversation_members
-- (verified below; left unchanged).
--
-- leave_fan_team / remove_fan_team_member still leave chat when the account
-- has NO remaining Team access. If a managed-player seat remains, chat stays.
--
-- PREPARE ONLY — do not auto-apply. No Edge deploy.
-- =============================================================================

DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
  v_is_player_src text;
BEGIN
  IF to_regclass('public.fan_teams') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.fan_teams'];
  END IF;
  IF to_regclass('public.fan_team_members') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.fan_team_members'];
  END IF;
  IF to_regclass('public.group_conversation_members') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.group_conversation_members'];
  END IF;
  IF to_regclass('public.fan_managed_player_guardians') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.fan_managed_player_guardians'];
  END IF;
  IF to_regprocedure('public.is_active_fan_team_member(uuid, uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['is_active_fan_team_member(uuid,uuid)'];
  END IF;
  IF to_regprocedure('public.fan_team_viewer_can_access_team(uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['fan_team_viewer_can_access_team(uuid)'];
  END IF;
  IF to_regprocedure('public.fan_team_chat_role_for_team_role(text)') IS NULL THEN
    v_missing := v_missing || ARRAY['fan_team_chat_role_for_team_role(text)'];
  END IF;
  IF to_regprocedure('public.leave_fan_team(uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['leave_fan_team(uuid)'];
  END IF;
  IF to_regprocedure('public.remove_fan_team_member(uuid, uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['remove_fan_team_member(uuid,uuid)'];
  END IF;
  IF to_regprocedure('public.set_my_fan_team_is_player(uuid, boolean)') IS NULL THEN
    v_missing := v_missing || ARRAY['set_my_fan_team_is_player(uuid,boolean)'];
  END IF;

  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION '20260997_0001 prerequisites missing: %',
      array_to_string(v_missing, ', ');
  END IF;

  SELECT p.prosrc INTO v_is_player_src
  FROM pg_catalog.pg_proc p
  WHERE p.oid = to_regprocedure('public.set_my_fan_team_is_player(uuid, boolean)');

  IF position('group_conversation_members' IN v_is_player_src) > 0 THEN
    RAISE EXCEPTION
      '20260997_0001 abort: set_my_fan_team_is_player already touches chat membership';
  END IF;
END $$;

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Account-level access probe (auth user or any user; not is_player)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fan_team_user_can_access_team(
  p_team_id uuid,
  p_user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT
    p_team_id IS NOT NULL
    AND p_user_id IS NOT NULL
    AND (
      public.is_active_fan_team_member(p_team_id, p_user_id)
      OR EXISTS (
        SELECT 1
        FROM public.fan_team_members m
        JOIN public.fan_managed_player_guardians g
          ON g.managed_player_id = m.managed_player_id
         AND g.guardian_user_id = p_user_id
         AND g.revoked_at IS NULL
        WHERE m.team_id = p_team_id
          AND m.managed_player_id IS NOT NULL
          AND m.left_at IS NULL
      )
    );
$$;

COMMENT ON FUNCTION public.fan_team_user_can_access_team(uuid, uuid) IS
  'Account can access this Team: active account seat OR guardian of an active managed seat. Not is_player.';

REVOKE ALL ON FUNCTION public.fan_team_user_can_access_team(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fan_team_user_can_access_team(uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.fan_team_user_can_access_team(uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.fan_team_user_can_access_team(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 2) Sync one account's Team Chat row to remaining account access
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_fan_team_chat_membership_for_user(
  p_team_id uuid,
  p_user_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_conversation_id uuid;
  v_team_active boolean;
  v_has_access boolean;
  v_account_role text;
  v_chat_role text;
BEGIN
  IF p_team_id IS NULL OR p_user_id IS NULL THEN
    RETURN;
  END IF;

  SELECT t.group_conversation_id, t.is_active
  INTO v_conversation_id, v_team_active
  FROM public.fan_teams t
  WHERE t.id = p_team_id;

  IF v_conversation_id IS NULL THEN
    RETURN;
  END IF;

  v_has_access :=
    coalesce(v_team_active, false)
    AND public.fan_team_user_can_access_team(p_team_id, p_user_id);

  IF v_has_access THEN
    SELECT m.role INTO v_account_role
    FROM public.fan_team_members m
    WHERE m.team_id = p_team_id
      AND m.user_id = p_user_id
      AND m.left_at IS NULL
    LIMIT 1;

    IF v_account_role IS NOT NULL THEN
      v_chat_role := public.fan_team_chat_role_for_team_role(v_account_role);
    ELSE
      v_chat_role := 'member';
    END IF;

    INSERT INTO public.group_conversation_members (
      conversation_id, user_id, role, joined_at, last_read_at
    ) VALUES (
      v_conversation_id, p_user_id, v_chat_role, now(), now()
    )
    ON CONFLICT (conversation_id, user_id) DO UPDATE
      SET left_at = NULL,
          role = EXCLUDED.role,
          joined_at = CASE
            WHEN public.group_conversation_members.left_at IS NOT NULL THEN now()
            ELSE public.group_conversation_members.joined_at
          END,
          last_read_at = coalesce(
            public.group_conversation_members.last_read_at,
            EXCLUDED.last_read_at
          );
  ELSE
    UPDATE public.group_conversation_members
    SET left_at = now(),
        role = 'member'
    WHERE conversation_id = v_conversation_id
      AND user_id = p_user_id
      AND left_at IS NULL;
  END IF;
END;
$$;

COMMENT ON FUNCTION public.sync_fan_team_chat_membership_for_user(uuid, uuid) IS
  'Ensure or revoke Team Chat membership from remaining account access. Not is_player.';

REVOKE ALL ON FUNCTION public.sync_fan_team_chat_membership_for_user(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.sync_fan_team_chat_membership_for_user(uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.sync_fan_team_chat_membership_for_user(uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.sync_fan_team_chat_membership_for_user(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3) Trigger: membership insert/leave/delete → sync affected accounts
--    Does NOT fire on is_player / jersey / role / permission updates.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fan_team_members_sync_chat_membership()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_team_id uuid;
  v_user_id uuid;
  v_managed_player_id uuid;
  v_guardian uuid;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_team_id := OLD.team_id;
    v_user_id := OLD.user_id;
    v_managed_player_id := OLD.managed_player_id;
  ELSE
    v_team_id := NEW.team_id;
    v_user_id := NEW.user_id;
    v_managed_player_id := NEW.managed_player_id;
  END IF;

  IF v_user_id IS NOT NULL THEN
    PERFORM public.sync_fan_team_chat_membership_for_user(v_team_id, v_user_id);
  END IF;

  IF v_managed_player_id IS NOT NULL THEN
    FOR v_guardian IN
      SELECT g.guardian_user_id
      FROM public.fan_managed_player_guardians g
      WHERE g.managed_player_id = v_managed_player_id
        AND g.revoked_at IS NULL
    LOOP
      PERFORM public.sync_fan_team_chat_membership_for_user(v_team_id, v_guardian);
    END LOOP;
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.fan_team_members_sync_chat_membership() IS
  'Keep Team Chat seats aligned with account access after membership insert/leave.';

REVOKE ALL ON FUNCTION public.fan_team_members_sync_chat_membership() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fan_team_members_sync_chat_membership() FROM anon;
REVOKE ALL ON FUNCTION public.fan_team_members_sync_chat_membership() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.fan_team_members_sync_chat_membership() TO service_role;

DROP TRIGGER IF EXISTS fan_team_members_sync_chat_membership_trg ON public.fan_team_members;
CREATE TRIGGER fan_team_members_sync_chat_membership_trg
  AFTER INSERT OR DELETE OR UPDATE OF left_at, user_id, managed_player_id
  ON public.fan_team_members
  FOR EACH ROW
  EXECUTE FUNCTION public.fan_team_members_sync_chat_membership();

-- ---------------------------------------------------------------------------
-- 4) leave / remove — only drop chat when NO remaining account access
-- ---------------------------------------------------------------------------
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
  v_team_name text;
  v_sport text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.';
  END IF;
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'User is required.';
  END IF;

  SELECT
    t.group_conversation_id,
    coalesce(nullif(btrim(t.name), ''), 'Team'),
    nullif(btrim(t.sport), '')
  INTO v_conversation_id, v_team_name, v_sport
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

  -- Keep chat if a managed-player seat still grants this account access.
  UPDATE public.group_conversation_members
  SET left_at = now(),
      role = 'member'
  WHERE conversation_id = v_conversation_id
    AND user_id = p_user_id
    AND left_at IS NULL
    AND NOT public.fan_team_user_can_access_team(p_team_id, p_user_id);

  UPDATE public.fan_teams
  SET updated_at = now()
  WHERE id = p_team_id;

  RAISE NOTICE
    '[FanTeamMemberLeaveDebug] remove_complete team_id=% removed_user_id=% actor=%',
    p_team_id, p_user_id, me;

  PERFORM public.clear_fan_notification_inbox_for_team_membership_loss(
    p_user_id,
    p_team_id
  );

  PERFORM public.emit_fan_team_member_change_notification(
    p_team_id,
    'removed_from_team',
    me,
    p_user_id,
    jsonb_build_object(
      'team_name', coalesce(v_team_name, 'Team'),
      'sport', coalesce(v_sport, ''),
      'previous_role', v_target_role
    )
  );
END;
$$;

COMMENT ON FUNCTION public.remove_fan_team_member(uuid, uuid) IS
  'STAFF soft-remove of another ACCOUNT member. Chat is revoked only when the '
  'account has no remaining Team access (managed-player seats keep Chat). '
  'Does not run on role/admin/is_player/managed-seat changes.';

REVOKE ALL ON FUNCTION public.remove_fan_team_member(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.remove_fan_team_member(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_fan_team_member(uuid, uuid) TO service_role;

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

  -- Soft-leave chat only when no remaining account access (Emma/other child).
  -- Demote admin so a later rejoin cannot revive manage rights.
  UPDATE public.group_conversation_members
  SET left_at = now(),
      role = 'member'
  WHERE conversation_id = v_conversation_id
    AND user_id = me
    AND left_at IS NULL
    AND NOT public.fan_team_user_can_access_team(p_team_id, me);

  UPDATE public.fan_team_invitations
  SET status = 'cancelled', cancelled_at = now(), responded_at = coalesce(responded_at, now())
  WHERE team_id = p_team_id
    AND invitee_user_id = me
    AND status = 'pending';

  UPDATE public.fan_teams
  SET updated_at = now()
  WHERE id = p_team_id;

  PERFORM public.clear_fan_notification_inbox_for_team_membership_loss(
    me,
    p_team_id
  );

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
  'Non-owner account soft-leave. Team Chat is revoked only when the account has '
  'no remaining Team access. Inbox clear + member_left_team APNS unchanged.';

REVOKE ALL ON FUNCTION public.leave_fan_team(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.leave_fan_team(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.leave_fan_team(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 5) Backfill: every account with Team access gets an active chat seat
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT DISTINCT t.id AS team_id, u.uid AS user_id
    FROM public.fan_teams t
    CROSS JOIN LATERAL (
      SELECT m.user_id AS uid
      FROM public.fan_team_members m
      WHERE m.team_id = t.id
        AND m.user_id IS NOT NULL
        AND m.left_at IS NULL
      UNION
      SELECT g.guardian_user_id
      FROM public.fan_team_members m
      JOIN public.fan_managed_player_guardians g
        ON g.managed_player_id = m.managed_player_id
       AND g.revoked_at IS NULL
      WHERE m.team_id = t.id
        AND m.managed_player_id IS NOT NULL
        AND m.left_at IS NULL
    ) u
    WHERE t.is_active IS TRUE
      AND t.group_conversation_id IS NOT NULL
      AND u.uid IS NOT NULL
  LOOP
    PERFORM public.sync_fan_team_chat_membership_for_user(r.team_id, r.user_id);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 6) Structural verification
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_is_player_src text;
  v_leave_src text;
  v_remove_src text;
  v_sync_src text;
BEGIN
  SELECT p.prosrc INTO v_is_player_src
  FROM pg_catalog.pg_proc p
  WHERE p.oid = to_regprocedure('public.set_my_fan_team_is_player(uuid, boolean)');
  IF position('group_conversation_members' IN v_is_player_src) > 0 THEN
    RAISE EXCEPTION '20260997 set_my_fan_team_is_player must not touch chat';
  END IF;

  SELECT p.prosrc INTO v_leave_src
  FROM pg_catalog.pg_proc p
  WHERE p.oid = to_regprocedure('public.leave_fan_team(uuid)');
  IF position('fan_team_user_can_access_team' IN v_leave_src) = 0 THEN
    RAISE EXCEPTION '20260997 leave_fan_team must gate chat leave on remaining access';
  END IF;

  SELECT p.prosrc INTO v_remove_src
  FROM pg_catalog.pg_proc p
  WHERE p.oid = to_regprocedure('public.remove_fan_team_member(uuid, uuid)');
  IF position('fan_team_user_can_access_team' IN v_remove_src) = 0 THEN
    RAISE EXCEPTION '20260997 remove_fan_team_member must gate chat leave on remaining access';
  END IF;

  SELECT p.prosrc INTO v_sync_src
  FROM pg_catalog.pg_proc p
  WHERE p.oid = to_regprocedure(
    'public.sync_fan_team_chat_membership_for_user(uuid, uuid)'
  );
  IF position('is_player' IN v_sync_src) > 0 THEN
    RAISE EXCEPTION '20260997 sync must not derive chat from is_player';
  END IF;

  IF to_regprocedure('public.fan_team_user_can_access_team(uuid, uuid)') IS NULL THEN
    RAISE EXCEPTION '20260997 fan_team_user_can_access_team missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_trigger
    WHERE tgname = 'fan_team_members_sync_chat_membership_trg'
  ) THEN
    RAISE EXCEPTION '20260997 chat sync trigger missing';
  END IF;
END $$;

COMMIT;
