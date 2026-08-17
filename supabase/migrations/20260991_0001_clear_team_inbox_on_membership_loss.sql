-- =============================================================================
-- 20260991_0001 — Clear Team FanGeo Inbox history on account membership loss
-- =============================================================================
-- When an ACCOUNT loses Team access (staff remove OR voluntary leave), mark
-- that user's prior fan_notification_inbox rows for that Team as cleared
-- BEFORE any new removed_from_team fan-out.
--
-- Soft-clear only: cleared_at = now() (and read_at if still unread). Same
-- canonical pattern as clear_my_fan_notification_inbox. No hard delete.
--
-- Scope:
--   user_id = lost-access account
--   team_id = that Team
--   cleared_at IS NULL
-- Does NOT touch other Teams, standalone Pickup (team_id IS NULL), or
-- Action Needed (live projection, not inbox rows).
--
-- Does NOT run on:
--   - Manager / Captain / Coach role changes
--   - Team Administrator ON/OFF
--   - set_my_fan_team_is_player (Myself seat off is not account leave)
--   - managed-player seat removal (account may still have access)
--
-- Voluntary leave: clears this Team's inbox for the leaver. Product still
-- does NOT send a "You left Team" inbox row to the leaving user. Owner /
-- Manager member_left notifications are unchanged (different user_id).
--
-- Order in remove_fan_team_member:
--   capture target → membership mutation → CLEAR prior Team inbox →
--   emit removed_from_team → fan-out NEW inbox row → APNs
-- Defense in depth: the helper never clears notification_type =
-- 'removed_from_team' so a future reorder cannot wipe the new row.
--
-- PREPARE ONLY — do not auto-apply. Apply after 20260990.
-- =============================================================================

DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.fan_notification_inbox') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.fan_notification_inbox'];
  END IF;
  IF to_regprocedure('public.emit_fan_team_member_change_notification(uuid, text, uuid, uuid, jsonb)') IS NULL THEN
    v_missing := v_missing || ARRAY['emit_fan_team_member_change_notification'];
  END IF;
  IF to_regprocedure('public.remove_fan_team_member(uuid, uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['remove_fan_team_member(uuid, uuid)'];
  END IF;
  IF to_regprocedure('public.leave_fan_team(uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['leave_fan_team(uuid)'];
  END IF;
  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION
      '20260991_0001 prerequisite missing: %',
      array_to_string(v_missing, ', ');
  END IF;
END $$;

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Internal helper — soft-clear one user's uncleared rows for one Team
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.clear_fan_notification_inbox_for_team_membership_loss(
  p_user_id uuid,
  p_team_id uuid
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_count integer := 0;
BEGIN
  IF p_user_id IS NULL OR p_team_id IS NULL THEN
    RETURN 0;
  END IF;

  UPDATE public.fan_notification_inbox i
  SET
    cleared_at = coalesce(i.cleared_at, pg_catalog.now()),
    read_at = coalesce(i.read_at, pg_catalog.now())
  WHERE i.user_id = p_user_id
    AND i.team_id = p_team_id
    AND i.cleared_at IS NULL
    AND i.notification_type IS DISTINCT FROM 'removed_from_team';

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

COMMENT ON FUNCTION public.clear_fan_notification_inbox_for_team_membership_loss(uuid, uuid) IS
  'Internal. Soft-clears uncleared fan_notification_inbox rows for one account on one '
  'Team (cleared_at/read_at). Skips removed_from_team so the post-removal durable row '
  'survives. Not granted to authenticated. Pickup (team_id NULL) and other Teams are '
  'untouched. Call AFTER membership mutation and BEFORE emit of removed_from_team.';

CREATE INDEX IF NOT EXISTS fan_notification_inbox_user_team_uncleared_idx
  ON public.fan_notification_inbox (user_id, team_id)
  WHERE cleared_at IS NULL AND team_id IS NOT NULL;

REVOKE ALL ON FUNCTION public.clear_fan_notification_inbox_for_team_membership_loss(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.clear_fan_notification_inbox_for_team_membership_loss(uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.clear_fan_notification_inbox_for_team_membership_loss(uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.clear_fan_notification_inbox_for_team_membership_loss(uuid, uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- 2) remove_fan_team_member — clear prior Team inbox, then emit removed_from_team
-- -----------------------------------------------------------------------------
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

  -- Capture target BEFORE left_at. Do not rediscover from roster after delete.
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

  -- Account lost Team access: clear THIS Team's prior inbox for the target.
  -- Must run AFTER left_at and BEFORE emit so the new removed_from_team row
  -- is not swept by the team_id clear.
  PERFORM public.clear_fan_notification_inbox_for_team_membership_loss(
    p_user_id,
    p_team_id
  );

  -- Explicit p_user_id captured above — never SELECT remaining members.
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
  'STAFF soft-remove of another ACCOUNT member. Captures p_user_id before left_at, '
  'clears that user''s prior FanGeo Inbox rows for this Team, then emits '
  'removed_from_team (durable inbox + notify-fan-team-member-change). '
  'Rejects self-removal. Does not run on role/admin/is_player/managed-seat changes. '
  'Managed seats use remove_fan_team_membership.';

REVOKE ALL ON FUNCTION public.remove_fan_team_member(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.remove_fan_team_member(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_fan_team_member(uuid, uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- 3) leave_fan_team — clear this Team's inbox for the leaver (no self "You left")
-- -----------------------------------------------------------------------------
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

  -- Account voluntarily lost Team access: clear THIS Team's prior inbox.
  -- Intentionally no "You left Team" durable row / APNs to the leaver.
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
  'Non-owner account soft-leave: membership + Team Chat (admin demoted) + invite cancel + '
  'future event cleanup + clear this Team''s FanGeo Inbox for the leaver + Owner/Manager '
  'member_left_team APNS queue. Does NOT emit a "You left Team" inbox row to the leaver.';

REVOKE ALL ON FUNCTION public.leave_fan_team(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.leave_fan_team(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.leave_fan_team(uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- 4) Structural verification
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_helper text;
  v_remove text;
  v_leave text;
  v_role text;
  v_perms text;
  v_player text;
  v_managed text;
  v_helper_oid oid;
  v_clear_pos integer;
  v_emit_pos integer;
BEGIN
  v_helper_oid := to_regprocedure(
    'public.clear_fan_notification_inbox_for_team_membership_loss(uuid, uuid)'
  );
  IF v_helper_oid IS NULL THEN
    RAISE EXCEPTION '20260991 helper missing';
  END IF;

  SELECT p.prosrc INTO v_helper FROM pg_catalog.pg_proc p WHERE p.oid = v_helper_oid;
  IF position('cleared_at' IN v_helper) = 0 THEN
    RAISE EXCEPTION '20260991 helper does not set cleared_at';
  END IF;
  IF position('DELETE FROM' IN upper(v_helper)) > 0 THEN
    RAISE EXCEPTION '20260991 helper must not hard-delete inbox rows';
  END IF;
  IF position('removed_from_team' IN v_helper) = 0 THEN
    RAISE EXCEPTION '20260991 helper must spare removed_from_team rows';
  END IF;

  SELECT p.prosrc INTO v_remove
  FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.remove_fan_team_member(uuid, uuid)'::regprocedure;
  v_clear_pos := position('clear_fan_notification_inbox_for_team_membership_loss' IN v_remove);
  v_emit_pos := position('emit_fan_team_member_change_notification' IN v_remove);
  IF v_clear_pos = 0 THEN
    RAISE EXCEPTION '20260991 remove_fan_team_member missing inbox clear';
  END IF;
  IF v_emit_pos = 0 THEN
    RAISE EXCEPTION '20260991 remove_fan_team_member missing emit';
  END IF;
  IF v_clear_pos > v_emit_pos THEN
    RAISE EXCEPTION
      '20260991 remove_fan_team_member must clear inbox BEFORE emit (clear@% emit@%)',
      v_clear_pos, v_emit_pos;
  END IF;
  IF position('SET left_at' IN v_remove) = 0
     OR position('SET left_at' IN v_remove) > v_clear_pos THEN
    RAISE EXCEPTION '20260991 remove_fan_team_member must mutate membership BEFORE clear';
  END IF;

  SELECT p.prosrc INTO v_leave
  FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.leave_fan_team(uuid)'::regprocedure;
  IF position('clear_fan_notification_inbox_for_team_membership_loss' IN v_leave) = 0 THEN
    RAISE EXCEPTION '20260991 leave_fan_team missing inbox clear';
  END IF;
  IF position('removed_from_team' IN v_leave) > 0
     OR position('emit_fan_team_member_change_notification' IN v_leave) > 0 THEN
    RAISE EXCEPTION '20260991 leave_fan_team must not emit removed_from_team to the leaver';
  END IF;

  -- Role / admin / Myself seat / managed-only remove must NOT clear Team inbox.
  SELECT p.prosrc INTO v_role
  FROM pg_catalog.pg_proc p
  WHERE p.proname = 'set_fan_team_member_role'
  ORDER BY p.oid DESC
  LIMIT 1;
  IF v_role IS NOT NULL
     AND position('clear_fan_notification_inbox_for_team_membership_loss' IN v_role) > 0 THEN
    RAISE EXCEPTION '20260991 set_fan_team_member_role must not clear Team inbox';
  END IF;

  IF to_regprocedure('public.set_fan_team_member_permissions(uuid, uuid, text[])') IS NOT NULL THEN
    SELECT p.prosrc INTO v_perms
    FROM pg_catalog.pg_proc p
    WHERE p.oid = 'public.set_fan_team_member_permissions(uuid, uuid, text[])'::regprocedure;
    IF position('clear_fan_notification_inbox_for_team_membership_loss' IN v_perms) > 0 THEN
      RAISE EXCEPTION '20260991 set_fan_team_member_permissions must not clear Team inbox';
    END IF;
  END IF;

  IF to_regprocedure('public.set_my_fan_team_is_player(uuid, boolean)') IS NOT NULL THEN
    SELECT p.prosrc INTO v_player
    FROM pg_catalog.pg_proc p
    WHERE p.oid = 'public.set_my_fan_team_is_player(uuid, boolean)'::regprocedure;
    IF position('clear_fan_notification_inbox_for_team_membership_loss' IN v_player) > 0 THEN
      RAISE EXCEPTION '20260991 set_my_fan_team_is_player must not clear Team inbox';
    END IF;
  END IF;

  IF to_regprocedure('public.remove_fan_team_membership(uuid)') IS NOT NULL THEN
    SELECT p.prosrc INTO v_managed
    FROM pg_catalog.pg_proc p
    WHERE p.oid = 'public.remove_fan_team_membership(uuid)'::regprocedure;
    -- Account seats delegate to remove_fan_team_member (which clears).
    -- The managed-seat path in this function must not call the helper directly.
    IF position('clear_fan_notification_inbox_for_team_membership_loss' IN v_managed) > 0 THEN
      RAISE EXCEPTION
        '20260991 remove_fan_team_membership must not clear inbox on managed-seat removal';
    END IF;
  END IF;

  RAISE NOTICE
    '[20260991] clear-on-membership-loss helper + remove/leave ordering verified';
END $$;

COMMIT;
