-- =============================================================================
-- 20260994_0001 — Team role mutation by roster seat (managed players)
-- =============================================================================
-- Product: Owner must set Captain / Member / etc. on a managed-player seat
-- (Emma) without touching the guardian account seat.
--
-- Proven defects (do not "fix" in client-only):
--   1) set_fan_team_member_role(p_team_id, p_user_id, p_role) keys by user_id.
--      Managed seats have user_id NULL → 0 rows / "not an active team member".
--   2) fan_team_members_managed_role_ck forces managed seats to role='member',
--      so even a correct UPDATE would raise 23514.
--
-- This migration:
--   * Relaxes the CHECK so managed seats may hold any assignable Team title
--     except Owner.
--   * Adds set_fan_team_membership_role(p_team_id, p_membership_id, p_role)
--     as the canonical write (account + managed).
--   * Rewrites set_fan_team_member_role as a thin resolver for account seats
--     only (unchanged signature).
--
-- AUTHORIZATION (Owner-only — established 20260926 product rule):
--   TEAM ROLE / TITLE ASSIGNMENT IS OWNER-LEVEL AUTHORITY.
--   Original set_fan_team_member_role (20260926) gated on
--     me <> owner_user_id → 'Only the team owner can change roles.'
--   20260950 broadened that to fan_team_viewer_can_manage (Manager may assign).
--   20260985 then made can_manage true for Team Administrator operational
--   keys, so a Manager title or Team Administrator could assign titles.
--   That broadening is NOT the product rule. This RPC restores Owner-only.
--   Owner transfer remains a separate Owner-only workflow.
--   Do NOT use fan_team_viewer_can_manage here.
--
-- Notifications: emit_fan_team_member_change_notification_for_membership
--   (account → member; managed → other guardians, never the actor).
-- Does NOT clear Team inbox. Does NOT auto-apply. No Edge deploy.
--
-- Rate limit: this migration also allowlists the new bucket (and the other
-- post-20260967 Team buckets) so apply does not depend on 20260995 order.
-- =============================================================================

DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.fan_team_members') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.fan_team_members'];
  END IF;
  IF to_regclass('public.fan_teams') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.fan_teams'];
  END IF;
  IF to_regclass('public.group_conversation_members') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.group_conversation_members'];
  END IF;
  IF to_regprocedure('public.assert_rpc_rate_limit(text,int,int)') IS NULL THEN
    v_missing := v_missing || ARRAY['assert_rpc_rate_limit(text,int,int)'];
  END IF;
  IF to_regprocedure(
       'public.emit_fan_team_member_change_notification_for_membership(uuid, text, uuid, uuid, jsonb)'
     ) IS NULL THEN
    v_missing := v_missing || ARRAY['emit_fan_team_member_change_notification_for_membership'];
  END IF;
  IF to_regprocedure('public.set_fan_team_member_role(uuid, uuid, text)') IS NULL THEN
    v_missing := v_missing || ARRAY['set_fan_team_member_role(uuid, uuid, text)'];
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'fan_team_members'
      AND column_name = 'membership_id'
  ) THEN
    v_missing := v_missing || ARRAY['column fan_team_members.membership_id'];
  END IF;
  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION
      '20260994_0001 prerequisite missing: %',
      array_to_string(v_missing, ', ');
  END IF;
END $$;

BEGIN;

-- -----------------------------------------------------------------------------
-- 0) Allowlist the new RPC bucket (and post-67 Team writes) before the RPC
--    can call assert_rpc_rate_limit. Preserves 20260967 buckets + semantics.
-- -----------------------------------------------------------------------------
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
    'set_my_teams_profile_visibility',
    'set_my_fan_team_is_player',
    'set_fan_team_member_permissions',
    'set_fan_team_membership_role'
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

-- -----------------------------------------------------------------------------
-- 1) Managed seats may hold assignable titles. Owner remains account-only.
-- -----------------------------------------------------------------------------
ALTER TABLE public.fan_team_members
  DROP CONSTRAINT IF EXISTS fan_team_members_managed_role_ck;

ALTER TABLE public.fan_team_members
  ADD CONSTRAINT fan_team_members_managed_role_ck
  CHECK (managed_player_id IS NULL OR role <> 'owner');

COMMENT ON CONSTRAINT fan_team_members_managed_role_ck ON public.fan_team_members IS
  'Managed-player seats cannot be Owner. Assignable titles (manager…member) are allowed.';

-- -----------------------------------------------------------------------------
-- 2) Canonical role write: target the membership row. Owner-only.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_fan_team_membership_role(
  p_team_id uuid,
  p_membership_id uuid,
  p_role text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  me uuid := (SELECT auth.uid());
  v_role text := lower(btrim(coalesce(p_role, '')));
  v_owner uuid;
  v_conversation_id uuid;
  v_old_role text;
  v_target_user uuid;
  v_target_managed uuid;
  v_group_role text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.' USING ERRCODE = '42501';
  END IF;
  IF p_team_id IS NULL OR p_membership_id IS NULL THEN
    RAISE EXCEPTION 'Team and membership are required.';
  END IF;
  IF v_role NOT IN (
    'manager',
    'head_coach',
    'assistant_coach',
    'captain',
    'assistant_captain',
    'member'
  ) THEN
    RAISE EXCEPTION 'Invalid role.';
  END IF;

  PERFORM public.assert_rpc_rate_limit('set_fan_team_membership_role', 60, 3600);

  SELECT t.owner_user_id, t.group_conversation_id
  INTO v_owner, v_conversation_id
  FROM public.fan_teams t
  WHERE t.id = p_team_id
    AND t.is_active IS TRUE;

  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Team not found.';
  END IF;

  -- Owner-only. Manager, Team Administrator, Coach, and Captain cannot assign titles.
  IF me IS DISTINCT FROM v_owner THEN
    RAISE EXCEPTION 'Only the team owner can change roles.';
  END IF;

  SELECT m.role, m.user_id, m.managed_player_id
  INTO v_old_role, v_target_user, v_target_managed
  FROM public.fan_team_members m
  WHERE m.membership_id = p_membership_id
    AND m.team_id = p_team_id
    AND m.left_at IS NULL
  FOR UPDATE;

  IF v_old_role IS NULL THEN
    RAISE EXCEPTION 'User is not an active team member.';
  END IF;

  IF lower(btrim(v_old_role)) = 'owner' OR v_target_user IS NOT DISTINCT FROM v_owner THEN
    RAISE EXCEPTION 'Cannot change the owner role this way.';
  END IF;

  IF v_target_managed IS NOT NULL AND v_role = 'owner' THEN
    RAISE EXCEPTION 'Invalid role.';
  END IF;

  RAISE NOTICE
    '[FanTeamRoleDebug] set_membership_role team_id=% membership_id=% managed_player_id=% user_id=% old_role=% new_role=% actor=%',
    p_team_id, p_membership_id, v_target_managed, v_target_user, v_old_role, v_role, me;

  IF v_old_role IS NOT DISTINCT FROM v_role THEN
    RETURN v_role;
  END IF;

  UPDATE public.fan_team_members
  SET role = v_role
  WHERE membership_id = p_membership_id
    AND team_id = p_team_id
    AND left_at IS NULL;

  -- Chat admin follows Team Manager for ACCOUNT seats only. Managed seats never
  -- join group_conversation_members.
  IF v_target_user IS NOT NULL AND v_conversation_id IS NOT NULL THEN
    v_group_role := CASE
      WHEN v_role = 'manager' THEN 'admin'
      ELSE 'member'
    END;
    UPDATE public.group_conversation_members
    SET role = v_group_role
    WHERE conversation_id = v_conversation_id
      AND user_id = v_target_user
      AND left_at IS NULL;
  END IF;

  PERFORM public.emit_fan_team_member_change_notification_for_membership(
    p_team_id,
    'team_role_changed',
    me,
    p_membership_id,
    jsonb_build_object('role', v_role, 'previous_role', v_old_role)
  );

  RETURN v_role;
END;
$$;

COMMENT ON FUNCTION public.set_fan_team_membership_role(uuid, uuid, text) IS
  'Owner-only. Assign a non-owner Team title to an active roster seat by '
  'membership_id (account or managed player). Does not change sibling seats. '
  'Does not clear inbox. team_role_changed: account target gets the member; '
  'managed target notifies other guardians, never the actor. Owner transfer '
  'is a separate workflow.';

REVOKE ALL ON FUNCTION public.set_fan_team_membership_role(uuid, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_fan_team_membership_role(uuid, uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_fan_team_membership_role(uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_fan_team_membership_role(uuid, uuid, text) TO service_role;

-- -----------------------------------------------------------------------------
-- 3) Legacy account RPC → resolve membership_id (never pass a guardian as Emma)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_fan_team_member_role(
  p_team_id uuid,
  p_user_id uuid,
  p_role text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_membership_id uuid;
BEGIN
  IF p_team_id IS NULL OR p_user_id IS NULL THEN
    RAISE EXCEPTION 'Team and user are required.';
  END IF;

  SELECT m.membership_id INTO v_membership_id
  FROM public.fan_team_members m
  WHERE m.team_id = p_team_id
    AND m.user_id = p_user_id
    AND m.left_at IS NULL;

  IF v_membership_id IS NULL THEN
    RAISE EXCEPTION 'User is not an active team member.';
  END IF;

  PERFORM public.set_fan_team_membership_role(p_team_id, v_membership_id, p_role);
END;
$$;

COMMENT ON FUNCTION public.set_fan_team_member_role(uuid, uuid, text) IS
  'Account-seat adapter. Resolves membership_id for user_id then calls '
  'set_fan_team_membership_role (Owner-only). Cannot target managed seats '
  '(user_id IS NULL).';

REVOKE ALL ON FUNCTION public.set_fan_team_member_role(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_fan_team_member_role(uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_fan_team_member_role(uuid, uuid, text) TO service_role;

-- -----------------------------------------------------------------------------
-- 4) Self-checks
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_def text;
  v_limit_src text;
BEGIN
  SELECT pg_catalog.pg_get_constraintdef(c.oid) INTO v_def
  FROM pg_catalog.pg_constraint c
  JOIN pg_catalog.pg_class t ON t.oid = c.conrelid
  JOIN pg_catalog.pg_namespace n ON n.oid = t.relnamespace
  WHERE n.nspname = 'public'
    AND t.relname = 'fan_team_members'
    AND c.conname = 'fan_team_members_managed_role_ck';
  IF v_def IS NULL OR position('owner' IN lower(v_def)) = 0 THEN
    RAISE EXCEPTION '20260994 managed_role_ck must forbid owner on managed seats';
  END IF;
  IF position('''member''' IN lower(v_def)) > 0
     AND position('<>' IN v_def) = 0 THEN
    RAISE EXCEPTION '20260994 managed_role_ck must not force role=member';
  END IF;

  IF to_regprocedure('public.set_fan_team_membership_role(uuid, uuid, text)') IS NULL THEN
    RAISE EXCEPTION '20260994 missing set_fan_team_membership_role';
  END IF;

  SELECT p.prosrc INTO v_def
  FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.set_fan_team_membership_role(uuid, uuid, text)'::regprocedure;
  IF position('clear_fan_notification_inbox_for_team_membership_loss' IN v_def) > 0 THEN
    RAISE EXCEPTION '20260994 set_fan_team_membership_role must not clear Team inbox';
  END IF;
  IF position('emit_fan_team_member_change_notification_for_membership' IN v_def) = 0 THEN
    RAISE EXCEPTION '20260994 set_fan_team_membership_role must emit via membership helper';
  END IF;
  IF position('assert_rpc_rate_limit' IN v_def) = 0 THEN
    RAISE EXCEPTION '20260994 set_fan_team_membership_role must call assert_rpc_rate_limit';
  END IF;
  IF position('fan_team_viewer_can_manage' IN v_def) > 0 THEN
    RAISE EXCEPTION '20260994 set_fan_team_membership_role must not use fan_team_viewer_can_manage';
  END IF;
  IF position('Only the team owner can change roles.' IN v_def) = 0 THEN
    RAISE EXCEPTION '20260994 set_fan_team_membership_role must be Owner-only';
  END IF;
  IF position('me IS DISTINCT FROM v_owner' IN v_def) = 0 THEN
    RAISE EXCEPTION '20260994 set_fan_team_membership_role must compare actor to owner_user_id';
  END IF;

  SELECT p.prosrc INTO v_limit_src
  FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.assert_rpc_rate_limit(text,int,int)'::regprocedure;
  IF v_limit_src IS NULL
     OR position('set_fan_team_membership_role' IN v_limit_src) = 0 THEN
    RAISE EXCEPTION '20260994 allowlist missing set_fan_team_membership_role';
  END IF;
END $$;

COMMIT;
