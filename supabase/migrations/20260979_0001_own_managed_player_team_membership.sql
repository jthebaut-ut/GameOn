-- =============================================================================
-- 20260979_0001 — Own managed-player Team membership (member self-service)
-- =============================================================================
-- Product: any ACTIVE account member may add/remove THEIR OWN managed players
-- on that Team. Role (owner/manager/captain/member/…) does not matter.
--
-- Security:
--   • add_managed_player_to_fan_team requires
--       is_authorized_managed_player_guardian(player, me)
--       AND is_active_fan_team_member(team, me)
--     Staff-only fan_team_viewer_can_manage is intentionally NOT required.
--   • remove_fan_team_membership for managed seats allows the guardian path
--       OR the existing staff (owner/manager) path
--   • Cannot add/remove another parent's child (unless staff remove)
--   • Cannot remove own account seat via this RPC (still leave_fan_team)
--   • Cannot remove the Team owner
--
-- Hardening (FINAL):
--   - SECURITY DEFINER search_path = pg_catalog, public
--   - schema-qualified relations / helpers / auth.uid() / now()
--   - unique-violation on concurrent add mapped to managed_player_already_on_team
--   - restore UPDATE is conditional on left_at IS NOT NULL
--   - remove FOR UPDATE of the membership row (no new advisory-lock namespace)
--   - duplicate active seats remain enforced by fan_team_members_active_managed_uidx
--   - add serializes on public.fan_teams row FOR UPDATE before cap check
--     (restore counts as a new active seat; duplicate error precedes cap)
--
-- Does NOT change: invitations, organizer permissions, roster leadership,
-- ownership, or leave_fan_team.
-- =============================================================================

DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.fan_teams') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.fan_teams'];
  END IF;
  IF to_regclass('public.fan_team_members') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.fan_team_members'];
  END IF;
  IF to_regclass('public.fan_geo_runtime_flags') IS NULL THEN
    v_missing := v_missing || ARRAY['table public.fan_geo_runtime_flags'];
  END IF;

  IF to_regprocedure('public.add_managed_player_to_fan_team(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['add_managed_player_to_fan_team(uuid,uuid)'];
  END IF;
  IF to_regprocedure('public.remove_fan_team_membership(uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['remove_fan_team_membership(uuid)'];
  END IF;
  IF to_regprocedure('public.remove_fan_team_member(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['remove_fan_team_member(uuid,uuid)'];
  END IF;
  IF to_regprocedure('public.is_authorized_managed_player_guardian(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['is_authorized_managed_player_guardian(uuid,uuid)'];
  END IF;
  IF to_regprocedure('public.is_active_fan_team_member(uuid,uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['is_active_fan_team_member(uuid,uuid)'];
  END IF;
  IF to_regprocedure('public.fan_team_viewer_can_manage(uuid)') IS NULL THEN
    v_missing := v_missing || ARRAY['fan_team_viewer_can_manage(uuid)'];
  END IF;
  IF to_regprocedure('public.is_fan_geo_runtime_flag_enabled(text)') IS NULL THEN
    v_missing := v_missing || ARRAY['is_fan_geo_runtime_flag_enabled(text)'];
  END IF;
  IF to_regprocedure('public.assert_rpc_rate_limit(text,int,int)') IS NULL THEN
    v_missing := v_missing || ARRAY['assert_rpc_rate_limit(text,int,int)'];
  END IF;
  IF to_regprocedure(
    'public.cleanup_fan_team_managed_member_future_event_participation(uuid,uuid,uuid)'
  ) IS NULL THEN
    v_missing := v_missing
      || ARRAY['cleanup_fan_team_managed_member_future_event_participation(uuid,uuid,uuid)'];
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'fan_team_members_active_managed_uidx'
      AND c.relkind = 'i'
  ) THEN
    v_missing := v_missing || ARRAY['index fan_team_members_active_managed_uidx'];
  END IF;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION
      '20260979_0001 prerequisites missing: %',
      array_to_string(v_missing, ', ');
  END IF;
END $$;

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) add_managed_player_to_fan_team — drop staff-only gate
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.add_managed_player_to_fan_team(
  p_team_id uuid,
  p_managed_player_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  me uuid := (SELECT auth.uid());
  v_membership_id uuid;
  v_team_active boolean;
  v_already_active boolean;
  v_active_count integer;
  v_updated integer;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.' USING ERRCODE = '42501';
  END IF;
  IF p_team_id IS NULL THEN
    RAISE EXCEPTION 'Team is required.';
  END IF;
  IF p_managed_player_id IS NULL THEN
    RAISE EXCEPTION 'Managed player is required.';
  END IF;

  IF NOT public.is_fan_geo_runtime_flag_enabled('managed_player_team_seats') THEN
    RAISE EXCEPTION 'managed_player_team_seats_disabled'
      USING ERRCODE = 'check_violation';
  END IF;

  -- Own managed players only. Same 42501 as membership failure (no oracle).
  IF NOT public.is_authorized_managed_player_guardian(p_managed_player_id, me) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  -- Viewer must hold an active account seat on this Team (any role).
  IF NOT public.is_active_fan_team_member(p_team_id, me) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  PERFORM public.assert_rpc_rate_limit('add_managed_player_to_fan_team', 30, 3600);

  -- Per-Team serialization for cap mutations. Held through restore/insert.
  SELECT t.is_active INTO v_team_active
  FROM public.fan_teams t
  WHERE t.id = p_team_id
  FOR UPDATE;

  IF v_team_active IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Team is no longer available.';
  END IF;

  -- Duplicate before cap: already-present child at 50 → already_on_team.
  SELECT EXISTS (
    SELECT 1
    FROM public.fan_team_members m
    WHERE m.team_id = p_team_id
      AND m.managed_player_id = p_managed_player_id
      AND m.left_at IS NULL
  ) INTO v_already_active;

  IF v_already_active THEN
    RAISE EXCEPTION 'managed_player_already_on_team'
      USING ERRCODE = 'unique_violation';
  END IF;

  -- Lock the latest soft-left seat so concurrent restore/insert serialize on
  -- this row. Duplicate actives are still rejected by
  -- fan_team_members_active_managed_uidx.
  SELECT m.membership_id INTO v_membership_id
  FROM public.fan_team_members m
  WHERE m.team_id = p_team_id
    AND m.managed_player_id = p_managed_player_id
    AND m.left_at IS NOT NULL
  ORDER BY m.joined_at DESC
  LIMIT 1
  FOR UPDATE OF m;

  SELECT EXISTS (
    SELECT 1
    FROM public.fan_team_members m
    WHERE m.team_id = p_team_id
      AND m.managed_player_id = p_managed_player_id
      AND m.left_at IS NULL
  ) INTO v_already_active;

  IF v_already_active THEN
    RAISE EXCEPTION 'managed_player_already_on_team'
      USING ERRCODE = 'unique_violation';
  END IF;

  -- Cap while Team row lock is held. Restore counts as a new active seat.
  SELECT count(*)::integer INTO v_active_count
  FROM public.fan_team_members m
  WHERE m.team_id = p_team_id
    AND m.left_at IS NULL;

  IF v_active_count >= 50 THEN
    RAISE EXCEPTION 'A team may have at most 50 members.';
  END IF;

  IF v_membership_id IS NOT NULL THEN
    BEGIN
      UPDATE public.fan_team_members
      SET left_at = NULL,
          joined_at = pg_catalog.now(),
          role = 'member'
      WHERE membership_id = v_membership_id
        AND left_at IS NOT NULL;
      GET DIAGNOSTICS v_updated = ROW_COUNT;
    EXCEPTION
      WHEN unique_violation THEN
        RAISE EXCEPTION 'managed_player_already_on_team'
          USING ERRCODE = 'unique_violation';
    END;

    IF v_updated = 1 THEN
      RETURN v_membership_id;
    END IF;
    -- Concurrent restore won; do not insert a second active seat.
    RAISE EXCEPTION 'managed_player_already_on_team'
      USING ERRCODE = 'unique_violation';
  END IF;

  BEGIN
    INSERT INTO public.fan_team_members (team_id, user_id, managed_player_id, role)
    VALUES (p_team_id, NULL, p_managed_player_id, 'member')
    RETURNING membership_id INTO v_membership_id;
  EXCEPTION
    WHEN unique_violation THEN
      RAISE EXCEPTION 'managed_player_already_on_team'
        USING ERRCODE = 'unique_violation';
  END;

  RETURN v_membership_id;
END;
$$;

COMMENT ON FUNCTION public.add_managed_player_to_fan_team(uuid, uuid) IS
  'Active Team account members may place THEIR OWN managed players on the Team. '
  'Requires is_authorized_managed_player_guardian + is_active_fan_team_member. '
  'Does not grant authority over another parent''s children. '
  'Serializes on fan_teams FOR UPDATE; 50-member cap includes restore. '
  'Duplicate active seat (managed_player_already_on_team) precedes cap. '
  'Gated by managed_player_team_seats runtime flag.';

-- -----------------------------------------------------------------------------
-- 2) remove_fan_team_membership — guardian self-service OR staff
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.remove_fan_team_membership(p_membership_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  me uuid := (SELECT auth.uid());
  v_team_id uuid;
  v_user_id uuid;
  v_managed_player_id uuid;
  v_role text;
  v_is_staff boolean;
  v_is_own_managed boolean;
  v_updated integer;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.' USING ERRCODE = '42501';
  END IF;
  IF p_membership_id IS NULL THEN
    RAISE EXCEPTION 'Membership is required.';
  END IF;

  SELECT m.team_id, m.user_id, m.managed_player_id, m.role
  INTO v_team_id, v_user_id, v_managed_player_id, v_role
  FROM public.fan_team_members m
  JOIN public.fan_teams t ON t.id = m.team_id AND t.is_active = true
  WHERE m.membership_id = p_membership_id
    AND m.left_at IS NULL
  FOR UPDATE OF m;

  -- Already left / missing / inactive Team: idempotent no-op.
  IF v_team_id IS NULL THEN
    RETURN;
  END IF;

  v_is_staff := public.fan_team_viewer_can_manage(v_team_id);
  v_is_own_managed :=
    v_managed_player_id IS NOT NULL
    AND public.is_authorized_managed_player_guardian(v_managed_player_id, me)
    AND public.is_active_fan_team_member(v_team_id, me);

  -- Account seat: staff-only remove of others; self must use leave_fan_team.
  IF v_user_id IS NOT NULL THEN
    IF NOT v_is_staff THEN
      RAISE EXCEPTION 'Only the owner or a manager can remove members.';
    END IF;
    IF v_role = 'owner' THEN
      RAISE EXCEPTION 'The team owner cannot be removed.';
    END IF;
    IF v_user_id = me THEN
      RAISE EXCEPTION 'Use leave_fan_team to leave the Team.';
    END IF;
    PERFORM public.remove_fan_team_member(v_team_id, v_user_id);
    RETURN;
  END IF;

  IF v_managed_player_id IS NULL THEN
    RETURN;
  END IF;

  -- Managed seat: guardian of this player with an account seat on the Team,
  -- OR owner/manager staff. Never another parent's child without staff rights.
  IF NOT (v_is_own_managed OR v_is_staff) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  -- Defense in depth: managed seats are constrained to role=member, but never
  -- allow an owner token through this path.
  IF v_role = 'owner' THEN
    RAISE EXCEPTION 'The team owner cannot be removed.';
  END IF;

  PERFORM public.cleanup_fan_team_managed_member_future_event_participation(
    v_team_id,
    p_membership_id,
    v_managed_player_id
  );

  UPDATE public.fan_team_members
  SET left_at = pg_catalog.now()
  WHERE membership_id = p_membership_id
    AND left_at IS NULL;
  GET DIAGNOSTICS v_updated = ROW_COUNT;

  IF v_updated = 0 THEN
    RETURN;
  END IF;

  UPDATE public.fan_teams
  SET updated_at = pg_catalog.now()
  WHERE id = v_team_id;

  RAISE NOTICE
    '[FanTeamMemberLeaveDebug] remove_membership_complete membership_id=% team_id=% managed_player_id=% actor=% own_managed=% staff=%',
    p_membership_id, v_team_id, v_managed_player_id, me, v_is_own_managed, v_is_staff;
END;
$$;

COMMENT ON FUNCTION public.remove_fan_team_membership(uuid) IS
  'Soft-remove by membership_id. Account seats: staff-only (self uses leave_fan_team). '
  'Managed seats: authorized guardian with an active account seat on the Team, '
  'or owner/manager staff. Does not archive the managed player globally.';

REVOKE ALL ON FUNCTION public.add_managed_player_to_fan_team(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.add_managed_player_to_fan_team(uuid, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.add_managed_player_to_fan_team(uuid, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.add_managed_player_to_fan_team(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.add_managed_player_to_fan_team(uuid, uuid) TO service_role;

REVOKE ALL ON FUNCTION public.remove_fan_team_membership(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.remove_fan_team_membership(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.remove_fan_team_membership(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.remove_fan_team_membership(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_fan_team_membership(uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- 3) Structural verification (no live JWT fixtures in this migration)
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_add text;
  v_remove text;
  v_cfg text[];
BEGIN
  SELECT p.proconfig INTO v_cfg
  FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.add_managed_player_to_fan_team(uuid,uuid)'::regprocedure;
  IF NOT EXISTS (
    SELECT 1
    FROM unnest(coalesce(v_cfg, ARRAY[]::text[])) cfg
    WHERE replace(cfg, ' ', '') = 'search_path=pg_catalog,public'
  ) THEN
    RAISE EXCEPTION 'FAIL: add_managed_player_to_fan_team search_path is not pg_catalog, public';
  END IF;
  IF NOT (
    SELECT p.prosecdef
    FROM pg_catalog.pg_proc p
    WHERE p.oid = 'public.add_managed_player_to_fan_team(uuid,uuid)'::regprocedure
  ) THEN
    RAISE EXCEPTION 'FAIL: add_managed_player_to_fan_team must be SECURITY DEFINER';
  END IF;

  SELECT p.proconfig INTO v_cfg
  FROM pg_catalog.pg_proc p
  WHERE p.oid = 'public.remove_fan_team_membership(uuid)'::regprocedure;
  IF NOT EXISTS (
    SELECT 1
    FROM unnest(coalesce(v_cfg, ARRAY[]::text[])) cfg
    WHERE replace(cfg, ' ', '') = 'search_path=pg_catalog,public'
  ) THEN
    RAISE EXCEPTION 'FAIL: remove_fan_team_membership search_path is not pg_catalog, public';
  END IF;
  IF NOT (
    SELECT p.prosecdef
    FROM pg_catalog.pg_proc p
    WHERE p.oid = 'public.remove_fan_team_membership(uuid)'::regprocedure
  ) THEN
    RAISE EXCEPTION 'FAIL: remove_fan_team_membership must be SECURITY DEFINER';
  END IF;

  SELECT pg_catalog.pg_get_functiondef(
    'public.add_managed_player_to_fan_team(uuid,uuid)'::regprocedure
  ) INTO v_add;
  IF position('fan_team_viewer_can_manage' IN v_add) > 0 THEN
    RAISE EXCEPTION 'FAIL: add_managed_player_to_fan_team must not require fan_team_viewer_can_manage';
  END IF;
  IF position('is_authorized_managed_player_guardian' IN v_add) = 0 THEN
    RAISE EXCEPTION 'FAIL: add_managed_player_to_fan_team must require guardian auth';
  END IF;
  IF position('is_active_fan_team_member' IN v_add) = 0 THEN
    RAISE EXCEPTION 'FAIL: add_managed_player_to_fan_team must require active account membership';
  END IF;
  IF position('managed_player_already_on_team' IN v_add) = 0 THEN
    RAISE EXCEPTION 'FAIL: add_managed_player_to_fan_team must reject duplicate add';
  END IF;
  IF position('unique_violation' IN v_add) = 0 THEN
    RAISE EXCEPTION 'FAIL: add_managed_player_to_fan_team must map concurrent unique_violation';
  END IF;
  IF position('assert_rpc_rate_limit' IN v_add) = 0 THEN
    RAISE EXCEPTION 'FAIL: add_managed_player_to_fan_team must keep rate limit';
  END IF;
  IF position('FOR UPDATE' IN v_add) = 0
     OR position('FROM public.fan_teams' IN v_add) = 0 THEN
    RAISE EXCEPTION 'FAIL: add_managed_player_to_fan_team must lock public.fan_teams FOR UPDATE';
  END IF;
  IF position('A team may have at most 50 members.' IN v_add) = 0 THEN
    RAISE EXCEPTION 'FAIL: add_managed_player_to_fan_team must enforce the 50-member cap';
  END IF;
  -- Order: Team row lock → duplicate → membership lock → cap (duplicate precedes cap).
  IF position('FOR UPDATE' IN v_add) >= position('managed_player_already_on_team' IN v_add) THEN
    RAISE EXCEPTION 'FAIL: Team FOR UPDATE must precede duplicate detection';
  END IF;
  IF position('FOR UPDATE OF m' IN v_add) = 0
     OR position('FOR UPDATE OF m' IN v_add)
        >= position('A team may have at most 50 members.' IN v_add) THEN
    RAISE EXCEPTION 'FAIL: restorable-seat lock must precede the 50-member cap check';
  END IF;
  IF position('managed_player_already_on_team' IN v_add)
     >= position('A team may have at most 50 members.' IN v_add) THEN
    RAISE EXCEPTION 'FAIL: duplicate detection must precede the 50-member cap check';
  END IF;

  SELECT pg_catalog.pg_get_functiondef(
    'public.remove_fan_team_membership(uuid)'::regprocedure
  ) INTO v_remove;
  IF position('is_authorized_managed_player_guardian' IN v_remove) = 0 THEN
    RAISE EXCEPTION 'FAIL: remove_fan_team_membership must allow guardian path for own managed seats';
  END IF;
  IF position('fan_team_viewer_can_manage' IN v_remove) = 0 THEN
    RAISE EXCEPTION 'FAIL: remove_fan_team_membership must retain staff path';
  END IF;
  IF position('leave_fan_team' IN v_remove) = 0 THEN
    RAISE EXCEPTION 'FAIL: remove_fan_team_membership must still reject self-account via leave_fan_team';
  END IF;
  IF position('The team owner cannot be removed.' IN v_remove) = 0 THEN
    RAISE EXCEPTION 'FAIL: remove_fan_team_membership must protect the Team owner';
  END IF;
  IF position('cleanup_fan_team_managed_member_future_event_participation' IN v_remove) = 0 THEN
    RAISE EXCEPTION 'FAIL: remove_fan_team_membership must clean future managed participation';
  END IF;
  IF position('FOR UPDATE OF m' IN v_remove) = 0 THEN
    RAISE EXCEPTION 'FAIL: remove_fan_team_membership must lock the membership row';
  END IF;

  -- Client RPCs.
  IF NOT pg_catalog.has_function_privilege(
    'authenticated',
    'public.add_managed_player_to_fan_team(uuid,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: authenticated missing EXECUTE on add_managed_player_to_fan_team';
  END IF;
  IF NOT pg_catalog.has_function_privilege(
    'authenticated',
    'public.remove_fan_team_membership(uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: authenticated missing EXECUTE on remove_fan_team_membership';
  END IF;
  IF pg_catalog.has_function_privilege(
    'anon',
    'public.add_managed_player_to_fan_team(uuid,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: anon must not EXECUTE add_managed_player_to_fan_team';
  END IF;
  IF pg_catalog.has_function_privilege(
    'anon',
    'public.remove_fan_team_membership(uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: anon must not EXECUTE remove_fan_team_membership';
  END IF;

  -- Internal helpers must remain non-client.
  IF pg_catalog.has_function_privilege(
    'authenticated',
    'public.is_authorized_managed_player_guardian(uuid,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: authenticated must not EXECUTE is_authorized_managed_player_guardian';
  END IF;
  IF pg_catalog.has_function_privilege(
    'authenticated',
    'public.is_active_fan_team_member(uuid,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: authenticated must not EXECUTE is_active_fan_team_member';
  END IF;
  IF pg_catalog.has_function_privilege(
    'authenticated',
    'public.is_fan_geo_runtime_flag_enabled(text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: authenticated must not EXECUTE is_fan_geo_runtime_flag_enabled';
  END IF;
  IF pg_catalog.has_function_privilege(
    'authenticated',
    'public.assert_rpc_rate_limit(text,int,int)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: authenticated must not EXECUTE assert_rpc_rate_limit';
  END IF;
  IF pg_catalog.has_function_privilege(
    'authenticated',
    'public.cleanup_fan_team_managed_member_future_event_participation(uuid,uuid,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: authenticated must not EXECUTE cleanup_fan_team_managed_member_future_event_participation';
  END IF;

  RAISE NOTICE '20260979 own-managed-player membership hardening checks PASSED.';
END $$;

-- Sequential staging checklist (JWT fixtures; not executed by this migration):
--   49 active → add new child → 50 succeeds
--   50 active → different child add → "A team may have at most 50 members."
--   50 active → already-present child → managed_player_already_on_team
--   soft-left restore at 49 → succeeds to 50
--   soft-left restore at 50 → cap rejected
-- Sequential SQL does NOT prove concurrency.
--
-- Manual Session A / Session B (start at 49 active; different children):
--   A: add_managed_player_to_fan_team(team, child_a)
--   B: add_managed_player_to_fan_team(team, child_b)  -- simultaneous
--   Expected: exactly one succeeds, one cap-fails, active count = 50,
--   no duplicate active seats, no deadlock.

COMMIT;
