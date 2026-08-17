-- =============================================================================
-- 20260989_0001 — Fix Team Administrator chat-admin sync (gcm 42P01)
-- =============================================================================
-- 20260987 failed to compile:
--   ERROR 42P01 invalid reference to FROM-clause entry for table "gcm"
--   LINE: AND m.user_id = gcm.user_id
--
-- Root cause: UPDATE target alias `gcm` was referenced in JOIN ON.
-- PostgreSQL only allows the target table in SET / WHERE / RETURNING
-- (and LATERAL). JOIN ON cannot see `gcm`.
--
-- This forward migration:
--   1) Re-applies Administrator backfill + role defaults (idempotent)
--   2) Rewrites the chat-admin sync with `gcm` only in SET/WHERE
--   3) Regression-checks the corrected UPDATE via EXPLAIN (must compile)
--
-- Preserves membership / ownership / Team rows. Does not weaken permissions.
-- PREPARE ONLY — apply after 20260986. Safe if 20260987 already ran or rolled back.
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
  IF to_regprocedure('public.fan_team_permission_keys()') IS NULL THEN
    v_missing := v_missing || ARRAY['fan_team_permission_keys()'];
  END IF;
  IF to_regprocedure('public.fan_team_effective_permissions(text,boolean,jsonb)') IS NULL THEN
    v_missing := v_missing || ARRAY['fan_team_effective_permissions(text,boolean,jsonb)'];
  END IF;
  IF to_regprocedure('public.fan_team_role_default_permissions(text)') IS NULL THEN
    v_missing := v_missing || ARRAY['fan_team_role_default_permissions(text)'];
  END IF;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION
      '20260989_0001 prerequisites missing: %',
      array_to_string(v_missing, ', ');
  END IF;
END $$;

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Administrator ON/OFF backfill (idempotent with 20260987)
-- -----------------------------------------------------------------------------
UPDATE public.fan_team_members m
SET
  granted_permissions = to_jsonb(public.fan_team_permission_keys()),
  use_custom_permissions = true
WHERE m.left_at IS NULL
  AND m.user_id IS NOT NULL
  AND m.managed_player_id IS NULL
  AND lower(btrim(coalesce(m.role, ''))) IS DISTINCT FROM 'owner'
  AND public.fan_team_effective_permissions(
        m.role,
        coalesce(m.use_custom_permissions, false),
        m.granted_permissions
      ) @> public.fan_team_permission_keys();

UPDATE public.fan_team_members m
SET
  granted_permissions = '[]'::jsonb,
  use_custom_permissions = false
WHERE m.left_at IS NULL
  AND m.user_id IS NOT NULL
  AND m.managed_player_id IS NULL
  AND lower(btrim(coalesce(m.role, ''))) IS DISTINCT FROM 'owner'
  AND NOT (
    public.fan_team_effective_permissions(
      m.role,
      coalesce(m.use_custom_permissions, false),
      m.granted_permissions
    ) @> public.fan_team_permission_keys()
  );

-- -----------------------------------------------------------------------------
-- 2) Role defaults: titles only (Owner retains full control)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fan_team_role_default_permissions(p_role text)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
  SELECT CASE lower(btrim(coalesce(p_role, 'member')))
    WHEN 'owner' THEN public.fan_team_permission_keys()
    ELSE ARRAY[]::text[]
  END;
$$;

COMMENT ON FUNCTION public.fan_team_role_default_permissions(text) IS
  'Role-title defaults: Owner = all management keys; every other role = none. '
  'Team Administrator is the Owner-assigned custom full set (20260987/20260989).';

-- -----------------------------------------------------------------------------
-- 3) Team Chat moderation flag — gcm only referenced from SET/WHERE
-- -----------------------------------------------------------------------------
UPDATE public.group_conversation_members gcm
SET role = CASE
  WHEN t.owner_user_id IS NOT DISTINCT FROM gcm.user_id THEN 'admin'
  WHEN 'moderate_team_chat' = ANY (
    public.fan_team_effective_permissions(
      m.role,
      coalesce(m.use_custom_permissions, false),
      m.granted_permissions
    )
  ) THEN 'admin'
  ELSE 'member'
END
FROM public.fan_teams t
JOIN public.fan_team_members m
  ON m.team_id = t.id
 AND m.left_at IS NULL
 AND m.user_id IS NOT NULL
WHERE gcm.conversation_id = t.group_conversation_id
  AND gcm.user_id IS NOT NULL
  AND m.user_id = gcm.user_id
  AND t.is_active IS TRUE
  AND t.group_conversation_id IS NOT NULL;

-- -----------------------------------------------------------------------------
-- 4) Regression: EXPLAIN must compile (42P01 if gcm is put back in JOIN ON)
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_owner text[];
  v_manager text[];
  v_member text[];
  v_keys text[];
BEGIN
  v_keys := public.fan_team_permission_keys();
  v_owner := public.fan_team_role_default_permissions('owner');
  v_manager := public.fan_team_role_default_permissions('manager');
  v_member := public.fan_team_role_default_permissions('member');

  IF v_owner IS DISTINCT FROM v_keys THEN
    RAISE EXCEPTION '20260989: owner role defaults must equal fan_team_permission_keys()';
  END IF;
  IF coalesce(array_length(v_manager, 1), 0) <> 0 THEN
    RAISE EXCEPTION '20260989: manager role defaults must be empty';
  END IF;
  IF coalesce(array_length(v_member, 1), 0) <> 0 THEN
    RAISE EXCEPTION '20260989: member role defaults must be empty';
  END IF;

  -- Parse/plan the corrected UPDATE. `AND false` prevents row changes.
  -- If `gcm` is referenced from JOIN ON, PostgreSQL raises 42P01 here.
  EXECUTE $q$
    EXPLAIN
    UPDATE public.group_conversation_members gcm
    SET role = gcm.role
    FROM public.fan_teams t
    JOIN public.fan_team_members m
      ON m.team_id = t.id
     AND m.left_at IS NULL
     AND m.user_id IS NOT NULL
    WHERE gcm.conversation_id = t.group_conversation_id
      AND gcm.user_id IS NOT NULL
      AND m.user_id = gcm.user_id
      AND t.is_active IS TRUE
      AND t.group_conversation_id IS NOT NULL
      AND false
  $q$;
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
